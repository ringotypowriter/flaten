const std = @import("std");
const flaten = @import("flaten");

/// Small demo executable that runs the pipeline on the built-in
/// test video and shows a full std.Progress-based progress bar
/// in the terminal.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = flaten.pipeline.PipelineConfig{
        .sample_rate = 16_000,
        .min_speech_ms = 300,
        .min_silence_ms = 200,
    };

    var progress = flaten.pipeline_progress.PipelineProgress.init(true);
    defer progress.deinit();

    const input_path = "test_resources/test.mp4";

    const srt = flaten.pipeline.transcribe_video_to_srt_with_progress(
        allocator,
        input_path,
        cfg,
        &progress,
    ) catch |err| {
        std.debug.print("Pipeline error in progress demo: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(srt);

    // Discard output; this executable is only meant to demonstrate the
    // progress bar behavior using std.Progress.
}

