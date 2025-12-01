const std = @import("std");
const subtitle_writer = @import("subtitle_writer.zig");
const audio_segmenter = @import("audio_segmenter.zig");
const asr_sherpa = @import("asr_sherpa.zig");
const ffmpeg_adapter = @import("ffmpeg_adapter.zig");
const pipeline_progress = @import("pipeline_progress.zig");

// Pipeline-level subtitle boundary padding (milliseconds) used when building SRT output.
const pre_pad_ms: u32 = 150;
const post_pad_ms: u32 = 150;

pub const OutputFormat = enum {
    /// Default behavior: output SRT subtitles with timestamps.
    srt,
    /// Plain text mode: each recognition result on its own line without timestamps.
    txt,
};

pub const PipelineConfig = struct {
    sample_rate: u32 = 16_000,
    min_speech_ms: u32 = 300,
    min_silence_ms: u32 = 200,
    /// ASR inference thread count forwarded to sherpa-onnx/ONNX Runtime.
    asr_num_threads: i32 = 2,
    /// Output format: SRT (default) or plain text.
    output_format: OutputFormat = .srt,
    /// Separator used when txt format is selected; defaults to "\n".
    txt_separator: []const u8 = "\n",
};

pub const Error = error{
    OutOfMemory,
    FfmpegFailed,
    IoFailed,
    AsrFailed,
    UnsupportedSampleRate,
};

/// Builds SRT subtitles on the original timeline from VAD segments and their ASR results.
/// - `segments[i]` represents a speech segment on the original audio timeline.
/// - `results_per_segment[i]` holds the recognition results for that segment (local timestamps starting at 0).
/// Local timestamps are shifted back to the original timeline:
///   global_ms = segment.start_ms + local_ms
pub fn buildSrtFromSegments(
    allocator: std.mem.Allocator,
    segments: []const audio_segmenter.SpeechSegment,
    results_per_segment: []const []const asr_sherpa.SegmentResult,
) ![]u8 {
    if (segments.len != results_per_segment.len) {
        // The caller must guarantee both lengths match; panic here to avoid adding more error variants to the upstream Error set.
        std.debug.panic("segments.len ({d}) != results_per_segment.len ({d})", .{
            segments.len,
            results_per_segment.len,
        });
    }

    var items = std.array_list.Managed(subtitle_writer.SubtitleItem).init(allocator);
    errdefer items.deinit();

    var index: usize = 1;
    for (segments, 0..) |seg, i| {
        const seg_results = results_per_segment[i];
        for (seg_results) |res| {
            const global_start = seg.start_ms + res.start_ms;
            const global_end = seg.start_ms + res.end_ms;
            try items.append(.{
                .index = index,
                .start_ms = global_start,
                .end_ms = global_end,
                .text = res.text,
            });
            index += 1;
        }
    }

    const srt = try subtitle_writer.formatSrt(allocator, items.items);
    items.deinit();
    return srt;
}

/// Concatenate segmented ASR results into plain text with one line per SegmentResult.
/// No timestamps; entries are joined in recognition order using `separator`.
pub fn buildTxtFromSegmentResults(
    allocator: std.mem.Allocator,
    results_per_segment: []const []const asr_sherpa.SegmentResult,
    separator: []const u8,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    var writer = buf.writer();
    var first = true;

    for (results_per_segment) |seg_results| {
        for (seg_results) |res| {
            // Skip empty transcripts to avoid emitting blank lines.
            if (res.text.len == 0) continue;

            if (!first) {
                try writer.writeAll(separator);
            } else {
                first = false;
            }
            try writer.writeAll(res.text);
        }
    }

    return buf.toOwnedSlice();
}

/// Placeholder pipeline that should wire ffmpeg -> VAD -> ASR -> SRT.
/// This variant does not expose progress tracking.
pub fn transcribe_video_to_srt(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
) Error![]u8 {
    return transcribe_video_to_srt_with_progress(allocator, input_path, cfg, null);
}

/// Pipeline variant that accepts an optional PipelineProgress for CLI
/// progress reporting.
pub fn transcribe_video_to_srt_with_progress(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
    progress: ?*pipeline_progress.PipelineProgress,
) Error![]u8 {
    return transcribe_video_to_srt_impl(allocator, input_path, cfg, progress);
}

fn transcribe_video_to_srt_impl(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
    progress: ?*pipeline_progress.PipelineProgress,
) Error![]u8 {
    if (progress) |p| {
        p.markStart();
    }

    // The ASR configuration is fixed at 16k sample rate to prevent mismatched sampling.
    if (cfg.sample_rate != 16_000) {
        return Error.UnsupportedSampleRate;
    }

    // 1. Use ffmpeg to decode the input file into mono s16le PCM.
    const pcm = try decodePcmFromFfmpeg(allocator, input_path, cfg.sample_rate, progress);
    defer allocator.free(pcm);
    if (progress) |p| {
        p.onFfmpegDone();
    }

    // 2. Use VAD to detect speech segments on the original timeline.
    const vad_cfg = audio_segmenter.VadConfig{
        .frame_ms = 20,
        .energy_threshold = 500,
        .min_speech_ms = cfg.min_speech_ms,
        .min_silence_ms = cfg.min_silence_ms,
    };
    const segments = try audio_segmenter.detect_speech_segments(
        allocator,
        pcm,
        cfg.sample_rate,
        vad_cfg,
    );
    defer allocator.free(segments);

    if (progress) |p| {
        p.setVadTotalSegments(segments.len);
        var i: usize = 0;
        while (i < segments.len) : (i += 1) {
            p.onVadSegmentDone();
        }
        p.onVadDone();
    }

    if (segments.len == 0) {
        // No speech segments were detected; return an empty SRT.
        return allocator.dupe(u8, "");
    }

    // 3. Call ASR for each speech segment separately; results remain in local time.
    var results_per_segment = std.array_list.Managed([]asr_sherpa.SegmentResult).init(allocator);
    errdefer cleanupAsrResults(&results_per_segment);

    if (progress) |p| {
        p.setAsrTotalSegments(segments.len);
    }

    for (segments) |seg| {
        const start_idx: usize = @intCast((seg.start_ms * cfg.sample_rate) / 1000);
        const end_idx: usize = @intCast((seg.end_ms * cfg.sample_rate) / 1000);
        if (start_idx >= end_idx or end_idx > pcm.len) {
            // Keep results_per_segment.len aligned with segments.len by padding an empty result.
            const empty = try allocator.alloc(asr_sherpa.SegmentResult, 0);
            try results_per_segment.append(empty);
            continue;
        }

        const window = pcm[start_idx..end_idx];
        const bytes = try encodePcm16ToBytes(allocator, window);
        defer allocator.free(bytes);

        const seg_results = asr_sherpa.recognizeWithThreads(
            allocator,
            bytes,
            cfg.asr_num_threads,
        ) catch {
            return Error.AsrFailed;
        };
        try results_per_segment.append(seg_results);
        if (progress) |p| {
            p.onAsrSegmentDone();
        }
    }

    if (progress) |p| {
        p.onAsrDone();
    }

    // 4. Apply light padding to the timeline before constructing the SRT so subtitles appear a bit early and disappear slightly late.
    // Alternatively, build the plain text output directly from the paragraphs.
    var output: []u8 = undefined;
    switch (cfg.output_format) {
        .srt => {
            const padded_segments = try padSegmentsForSrt(allocator, segments);
            defer allocator.free(padded_segments);

            // Map the local timestamps back to the original timeline to generate the final SRT.
            if (progress) |p| {
                // Treat SRT building as a single unit of work for now.
                p.setSrtTotalItems(1);
                p.onSrtItemDone();
                p.onSrtDone();
            }

            output = try buildSrtFromSegments(
                allocator,
                padded_segments,
                results_per_segment.items,
            );
        },
        .txt => {
            if (progress) |p| {
                // Treat txt output as a single step for consistent progress tracking.
                p.setSrtTotalItems(1);
                p.onSrtItemDone();
                p.onSrtDone();
            }

            output = try buildTxtFromSegmentResults(
                allocator,
                results_per_segment.items,
                cfg.txt_separator,
            );
        },
    }

    if (progress) |p| {
        p.markEnd();
    }
    cleanupAsrResults(&results_per_segment);
    return output;
}

test "buildSrtFromSegments maps local time to global timeline" {
    const gpa = std.testing.allocator;

    const segments = [_]audio_segmenter.SpeechSegment{
        .{ .start_ms = 0, .end_ms = 500 },
    };
    const asr_results_seg0 = [_]asr_sherpa.SegmentResult{
        .{ .start_ms = 0, .end_ms = 500, .text = "HELLO" },
    };

    const srt = try buildSrtFromSegments(
        gpa,
        &segments,
        &.{asr_results_seg0[0..]},
    );
    defer gpa.free(srt);

    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "HELLO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "00:00:00,000"));
}

test "buildTxtFromSegmentResults flattens results into newline-separated text" {
    const gpa = std.testing.allocator;

    const seg0 = [_]asr_sherpa.SegmentResult{
        .{ .start_ms = 0, .end_ms = 500, .text = "HELLO" },
        .{ .start_ms = 500, .end_ms = 900, .text = "" }, // empty should be skipped
    };
    const seg1 = [_]asr_sherpa.SegmentResult{
        .{ .start_ms = 1000, .end_ms = 1500, .text = "WORLD" },
    };

    const txt = try buildTxtFromSegmentResults(
        gpa,
        &.{ seg0[0..], seg1[0..] },
        "\n",
    );
    defer gpa.free(txt);

    try std.testing.expectEqualStrings("HELLO\nWORLD", txt);
}

test "buildSrtFromSegments preserves gaps between speech segments" {
    const gpa = std.testing.allocator;

    // Two speech segments: 1s-2s and 4s-5s with silence between them.
    const segments = [_]audio_segmenter.SpeechSegment{
        .{ .start_ms = 1_000, .end_ms = 2_000 },
        .{ .start_ms = 4_000, .end_ms = 5_000 },
    };

    const asr_results_seg0 = [_]asr_sherpa.SegmentResult{
        .{ .start_ms = 0, .end_ms = 500, .text = "HELLO" },
    };
    const asr_results_seg1 = [_]asr_sherpa.SegmentResult{
        .{ .start_ms = 0, .end_ms = 500, .text = "WORLD" },
    };

    const srt = try buildSrtFromSegments(
        gpa,
        &segments,
        &.{ asr_results_seg0[0..], asr_results_seg1[0..] },
    );
    defer gpa.free(srt);

    // Expect the first subtitle around 1.0-1.5s, the second around 4.0-4.5s, and numbering remains consecutive.
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "1\n00:00:01,000 --> 00:00:01,500"));
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "HELLO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "2\n00:00:04,000 --> 00:00:04,500"));
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "WORLD"));
}

test "transcribe_video_to_srt runs on example mp4 (stub ASR)" {
    const gpa = std.testing.allocator;

    const cfg = PipelineConfig{
        .sample_rate = 16_000,
        .min_speech_ms = 300,
        .min_silence_ms = 200,
    };

    const srt = try transcribe_video_to_srt(gpa, "test_resources/test.mp4", cfg);
    defer gpa.free(srt);

    // Allow empty results (e.g., near silent audio); if not empty, verify SRT structure looks reasonable.
    if (srt.len > 0) {
        try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, " --> "));
    }
}

test "transcribe_video_to_srt_with_progress runs and updates progress" {
    const gpa = std.testing.allocator;

    const cfg = PipelineConfig{
        .sample_rate = 16_000,
        .min_speech_ms = 300,
        .min_silence_ms = 200,
    };

    var progress = pipeline_progress.PipelineProgress.initNoOp();
    defer progress.deinit();

    const srt = try transcribe_video_to_srt_with_progress(
        gpa,
        "test_resources/test.mp4",
        cfg,
        &progress,
    );
    defer gpa.free(srt);

    // Allow empty results (e.g., near silent audio); if not empty, verify SRT structure looks reasonable.
    if (srt.len > 0) {
        try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, " --> "));
    }

    // Basic sanity: counters should be internally consistent.
    try std.testing.expect(progress.ffmpeg_completed_samples <= progress.ffmpeg_total_samples);

    // Pipeline should have marked start and end timestamps.
    try std.testing.expect(progress.start_time_ns != 0);
    try std.testing.expect(progress.end_time_ns != 0);
    try std.testing.expect(progress.end_time_ns >= progress.start_time_ns);
}

fn padSegmentsForSrt(
    allocator: std.mem.Allocator,
    segments: []const audio_segmenter.SpeechSegment,
) ![]audio_segmenter.SpeechSegment {
    const out = try allocator.alloc(audio_segmenter.SpeechSegment, segments.len);

    for (segments, 0..) |seg, i| {
        var start = seg.start_ms;
        var end = seg.end_ms;

        if (pre_pad_ms > 0) {
            if (start > pre_pad_ms) {
                start -= pre_pad_ms;
            } else {
                start = 0;
            }
        }

        end += post_pad_ms;

        out[i] = .{
            .start_ms = start,
            .end_ms = end,
        };
    }

    return out;
}

fn cleanupAsrResults(list: *std.array_list.Managed([]asr_sherpa.SegmentResult)) void {
    const allocator = list.allocator;
    for (list.items) |seg_results| {
        for (seg_results) |seg| {
            allocator.free(seg.text);
        }
        allocator.free(seg_results);
    }
    list.deinit();
}

fn decodePcmFromFfmpeg(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    sample_rate: u32,
    progress: ?*pipeline_progress.PipelineProgress,
) Error![]i16 {
    const argv = ffmpeg_adapter.build_ffmpeg_cmd(
        .{ .input_path = input_path, .sample_rate = sample_rate, .mono = true },
        allocator,
    ) catch return Error.FfmpegFailed;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return Error.FfmpegFailed;

    var stdout_file = child.stdout orelse return Error.FfmpegFailed;

    var byte_list = std.array_list.Managed(u8).init(allocator);
    errdefer byte_list.deinit();

    var read_buf: [4096]u8 = undefined;
    var total_samples_read: usize = 0;
    while (true) {
        const n = stdout_file.read(&read_buf) catch return Error.IoFailed;
        if (n == 0) break;
        byte_list.appendSlice(read_buf[0..n]) catch return Error.OutOfMemory;
        if (progress) |p| {
            // 2 bytes per sample for s16le.
            const delta_samples: usize = n / 2;
            total_samples_read += delta_samples;
            p.addFfmpegDecodedSamples(delta_samples);
        }
    }

    const term = child.wait() catch return Error.FfmpegFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return Error.FfmpegFailed;
        },
        else => return Error.FfmpegFailed,
    }

    const total_bytes = byte_list.items.len;
    const even_bytes = total_bytes - (total_bytes % 2);
    if (even_bytes == 0) {
        byte_list.deinit();
        return allocator.alloc(i16, 0);
    }

    const sample_count: usize = even_bytes / 2;
    if (progress) |p| {
        if (p.ffmpeg_total_samples == 0) {
            p.setFfmpegTotalSamples(sample_count);
        }
    }
    var samples = allocator.alloc(i16, sample_count) catch return Error.OutOfMemory;

    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const lo: u16 = byte_list.items[i * 2];
        const hi: u16 = byte_list.items[i * 2 + 1];
        const packed_val: u16 = (hi << 8) | lo;
        samples[i] = @bitCast(packed_val);
    }

    byte_list.deinit();
    return samples;
}

fn encodePcm16ToBytes(allocator: std.mem.Allocator, pcm: []const i16) ![]u8 {
    const byte_len: usize = pcm.len * 2;
    var out = try allocator.alloc(u8, byte_len);
    var i: usize = 0;
    while (i < pcm.len) : (i += 1) {
        const v: u16 = @bitCast(pcm[i]);
        out[i * 2] = @intCast(v & 0xff);
        out[i * 2 + 1] = @intCast((v >> 8) & 0xff);
    }
    return out;
}
