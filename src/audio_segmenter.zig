const std = @import("std");

pub const SpeechSegment = struct {
    start_ms: u64,
    end_ms: u64,
};

pub const VadConfig = struct {
    frame_ms: u32 = 20,
    energy_threshold: i32 = 500,
    min_speech_ms: u32 = 300,
    min_silence_ms: u32 = 200,
};

/// VAD 错误类型。目前只可能出现内存不足。
pub const Error = error{OutOfMemory};

pub fn detect_speech_segments(
    allocator: std.mem.Allocator,
    pcm: []const i16,
    sample_rate: u32,
    config: VadConfig,
) Error![]SpeechSegment {
    if (pcm.len == 0 or sample_rate == 0) {
        return &.{};
    }

    const frame_samples: usize = @intCast((@as(u64, config.frame_ms) * sample_rate) / 1000);
    if (frame_samples == 0) {
        return &.{};
    }

    var segments = std.array_list.Managed(SpeechSegment).init(allocator);
    errdefer segments.deinit();

    var in_speech = false;
    var seg_start_ms: u64 = 0;
    var last_voiced_end_ms: u64 = 0;
    var current_silence_ms: u64 = 0;

    var i: usize = 0;
    while (i < pcm.len) : (i += frame_samples) {
        const frame_start = i;
        const frame_end = @min(pcm.len, i + frame_samples);

        var max_abs: i32 = 0;
        var j = frame_start;
        while (j < frame_end) : (j += 1) {
            const v: i32 = @intCast(pcm[j]);
            const abs_v = if (v < 0) -v else v;
            if (abs_v > max_abs) max_abs = abs_v;
        }

        const frame_ms_start: u64 = @intCast((@as(u64, frame_start) * 1000) / sample_rate);
        const frame_ms_end: u64 = @intCast((@as(u64, frame_end) * 1000) / sample_rate);

        const voiced = max_abs >= config.energy_threshold;

        if (voiced) {
            if (!in_speech) {
                in_speech = true;
                seg_start_ms = frame_ms_start;
                current_silence_ms = 0;
            }
            last_voiced_end_ms = frame_ms_end;
            // 只要再次出现有声帧，静音累积清零
            current_silence_ms = 0;
        } else if (in_speech) {
            // 语音段内部的静音：累积时长，直到超过 min_silence_ms 才真正收尾
            current_silence_ms += frame_ms_end - frame_ms_start;
            if (current_silence_ms >= config.min_silence_ms) {
                const duration = last_voiced_end_ms - seg_start_ms;
                if (duration >= config.min_speech_ms) {
                    try segments.append(.{
                        .start_ms = seg_start_ms,
                        .end_ms = last_voiced_end_ms,
                    });
                }
                in_speech = false;
                current_silence_ms = 0;
            }
        }
    }

    // 音频结尾仍在语音段中，做一次收尾
    if (in_speech) {
        const duration = last_voiced_end_ms - seg_start_ms;
        if (duration >= config.min_speech_ms) {
            try segments.append(.{
                .start_ms = seg_start_ms,
                .end_ms = last_voiced_end_ms,
            });
        }
    }

    return segments.toOwnedSlice();
}

test "single voiced region is detected" {
    const gpa = std.testing.allocator;

    // 3 seconds of audio @16k: 0-1s silence, 1-2s tone, 2-3s silence
    const sample_rate: u32 = 16_000;
    const total_samples = 3 * sample_rate;
    var pcm = try gpa.alloc(i16, total_samples);
    defer gpa.free(pcm);

    // fill: first 1s zeros, next 1s amplitude 2000, final 1s zeros
    for (pcm[0..sample_rate]) |*s| s.* = 0;
    for (pcm[sample_rate .. 2 * sample_rate]) |*s| s.* = 2000;
    for (pcm[2 * sample_rate ..]) |*s| s.* = 0;

    const segments = try detect_speech_segments(gpa, pcm, sample_rate, .{});
    defer gpa.free(segments);
    // expect one segment around 1000-2000ms (allowing frame jitter later)
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expect(segments[0].start_ms <= 1100 and segments[0].start_ms >= 900);
    try std.testing.expect(segments[0].end_ms <= 2100 and segments[0].end_ms >= 1900);
}

test "short blips below min_speech_ms are ignored" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 16_000;
    const total_samples = 2 * sample_rate;
    var pcm = try gpa.alloc(i16, total_samples);
    defer gpa.free(pcm);

    // 50 ms blip at 500ms
    for (pcm) |*s| s.* = 0;
    const start = (500 * sample_rate) / 1000;
    const blip_len = (50 * sample_rate) / 1000;
    for (pcm[start .. start + blip_len]) |*s| s.* = 4000;

    const cfg = VadConfig{ .min_speech_ms = 200 };
    const segments = try detect_speech_segments(gpa, pcm, sample_rate, cfg);
    defer gpa.free(segments);
    try std.testing.expectEqual(@as(usize, 0), segments.len);
}

test "short silence inside speech does not split segment when below min_silence_ms" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 16_000;
    const total_ms: u32 = 1200;
    const total_samples: usize = @intCast((@as(u64, total_ms) * sample_rate) / 1000);
    var pcm = try gpa.alloc(i16, total_samples);
    defer gpa.free(pcm);

    // 0-400ms: voiced
    // 400-500ms: short silence (< min_silence_ms = 200ms)
    // 500-900ms: voiced
    // 900-1200ms: silence
    const s0 = (0 * sample_rate) / 1000;
    const s1 = (400 * sample_rate) / 1000;
    const s2 = (500 * sample_rate) / 1000;
    const s3 = (900 * sample_rate) / 1000;

    for (pcm[0..s0]) |*s| s.* = 0;
    for (pcm[s0..s1]) |*s| s.* = 3000;
    for (pcm[s1..s2]) |*s| s.* = 0;
    for (pcm[s2..s3]) |*s| s.* = 3000;
    for (pcm[s3..]) |*s| s.* = 0;

    const cfg = VadConfig{
        .min_speech_ms = 200,
        .min_silence_ms = 200,
    };
    const segments = try detect_speech_segments(gpa, pcm, sample_rate, cfg);
    defer gpa.free(segments);

    // 期望被视为一个连续语音段，大约覆盖 0–900ms。
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expect(segments[0].start_ms <= 100 and segments[0].start_ms <= 100);
    try std.testing.expect(segments[0].end_ms >= 800 and segments[0].end_ms <= 1000);
}

test "longer silence splits into two segments when above min_silence_ms" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 16_000;
    const total_ms: u32 = 1600;
    const total_samples: usize = @intCast((@as(u64, total_ms) * sample_rate) / 1000);
    var pcm = try gpa.alloc(i16, total_samples);
    defer gpa.free(pcm);

    // 0-400ms: voiced
    // 400-700ms: silence (300ms > min_silence_ms)
    // 700-1100ms: voiced
    // 1100-1600ms: silence
    const s0 = (0 * sample_rate) / 1000;
    const s1 = (400 * sample_rate) / 1000;
    const s2 = (700 * sample_rate) / 1000;
    const s3 = (1100 * sample_rate) / 1000;

    for (pcm[0..s0]) |*s| s.* = 0;
    for (pcm[s0..s1]) |*s| s.* = 3000;
    for (pcm[s1..s2]) |*s| s.* = 0;
    for (pcm[s2..s3]) |*s| s.* = 3000;
    for (pcm[s3..]) |*s| s.* = 0;

    const cfg = VadConfig{
        .min_speech_ms = 200,
        .min_silence_ms = 200,
    };
    const segments = try detect_speech_segments(gpa, pcm, sample_rate, cfg);
    defer gpa.free(segments);

    try std.testing.expectEqual(@as(usize, 2), segments.len);
    // 第一段大约在 0-400ms
    try std.testing.expect(segments[0].start_ms <= 100);
    try std.testing.expect(segments[0].end_ms >= 300 and segments[0].end_ms <= 500);
    // 第二段大约在 700-1100ms
    try std.testing.expect(segments[1].start_ms >= 600 and segments[1].start_ms <= 800);
    try std.testing.expect(segments[1].end_ms >= 1000 and segments[1].end_ms <= 1200);
}
