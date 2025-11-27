//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const subtitle_writer = @import("subtitle_writer.zig");
pub const cli_options = @import("cli_options.zig");
pub const audio_segmenter = @import("audio_segmenter.zig");
pub const ffmpeg_adapter = @import("ffmpeg_adapter.zig");
pub const asr_sherpa = @import("asr_sherpa.zig");
pub const pipeline = @import("pipeline.zig");
pub const model_manager = @import("model_manager.zig");
pub const pipeline_progress = @import("pipeline_progress.zig");

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}
