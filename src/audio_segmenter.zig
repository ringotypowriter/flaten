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
pub const Error = error{ OutOfMemory };

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
            }
            last_voiced_end_ms = frame_ms_end;
        } else if (in_speech) {
            // 结束一个语音段，检查是否满足最小持续时间
            const duration = last_voiced_end_ms - seg_start_ms;
            if (duration >= config.min_speech_ms) {
                try segments.append(.{
                    .start_ms = seg_start_ms,
                    .end_ms = last_voiced_end_ms,
                });
            }
            in_speech = false;
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
    for (pcm[0 .. sample_rate]) |*s| s.* = 0;
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
