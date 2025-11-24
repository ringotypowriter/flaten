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

/// Placeholder VAD implementation; to be filled in later TDD steps.
pub const Error = error{Todo};

pub fn detect_speech_segments(
    allocator: std.mem.Allocator,
    pcm: []const i16,
    sample_rate: u32,
    config: VadConfig,
) Error![]SpeechSegment {
    _ = allocator;
    _ = pcm;
    _ = sample_rate;
    _ = config;
    return Error.Todo;
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
    try std.testing.expectEqual(@as(usize, 0), segments.len);
}
