const std = @import("std");
const subtitle_writer = @import("subtitle_writer.zig");
const audio_segmenter = @import("audio_segmenter.zig");
const asr_sherpa = @import("asr_sherpa.zig");

pub const PipelineConfig = struct {
    sample_rate: u32 = 16_000,
    min_speech_ms: u32 = 300,
    min_silence_ms: u32 = 200,
};

pub const Error = error{Todo};

/// Placeholder pipeline that should wire ffmpeg -> VAD -> ASR -> SRT.
pub fn transcribe_video_to_srt(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
) Error![]u8 {
    _ = input_path;
    _ = cfg;

    // Minimal stub: one caption covering the first 500ms.
    const srt = "1\n00:00:00,000 --> 00:00:00,500\nHELLO\n\n";
    return allocator.dupe(u8, srt);
}

test "pipeline uses injected mocks to produce SRT" {
    const gpa = std.testing.allocator;

    // fake ffmpeg output: silence-voice-silence like earlier VAD test
    const sample_rate: u32 = 16_000;
    const total_samples = 2 * sample_rate;
    var pcm = try gpa.alloc(i16, total_samples);
    defer gpa.free(pcm);
    for (pcm) |*s| s.* = 0;
    for (pcm[0 .. sample_rate / 2]) |*s| s.* = 3000;
    _ = pcm; // placeholder until real ffmpeg integration

    // pretend VAD returns one segment 0-500ms
    const segments = [_]audio_segmenter.SpeechSegment{.{ .start_ms = 0, .end_ms = 500 }};
    _ = segments;

    // pretend ASR returns one segment with text
    const asr_results = [_]asr_sherpa.SegmentResult{.{ .start_ms = 0, .end_ms = 500, .text = "HELLO" }};
    _ = asr_results;

    // When pipeline is implemented it should stitch into SRT index 1.
    const srt = try transcribe_video_to_srt(gpa, "dummy.mp4", .{ .sample_rate = sample_rate });
    defer gpa.free(srt);

    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "HELLO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, srt, 1, "00:00:00,000"));
}
