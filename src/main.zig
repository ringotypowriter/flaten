const std = @import("std");
const flaten = @import("flaten");

fn printUsage() !void {
    std.debug.print(
        "Usage: flaten --input <input> [--output <output>] [--format <srt|txt>] [--sample-rate <hz>] [--min-speech-ms <ms>] [--min-silence-ms <ms>] [--asr-num-threads <n>]\n",
        .{},
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try printUsage();
        return error.InvalidArgs;
    }

    const opts = flaten.cli_options.parse(allocator, args[1..]) catch |err| {
        std.debug.print("Failed to parse arguments: {s}\n", .{@errorName(err)});
        try printUsage();
        return err;
    };
    defer allocator.free(opts.input_path);
    defer allocator.free(opts.output_path);

    const cfg = flaten.pipeline.PipelineConfig{
        .sample_rate = opts.sample_rate,
        .min_speech_ms = opts.min_speech_ms,
        .min_silence_ms = opts.min_silence_ms,
        .asr_num_threads = opts.asr_num_threads,
        .output_format = switch (opts.format) {
            .srt => .srt,
            .txt => .txt,
        },
    };

    var progress = flaten.pipeline_progress.PipelineProgress.init(true);
    defer progress.deinit();

    const srt = flaten.pipeline.transcribe_video_to_srt_with_progress(
        allocator,
        opts.input_path,
        cfg,
        &progress,
    ) catch |err| {
        std.debug.print("Pipeline error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(srt);

    var file = try std.fs.cwd().createFile(opts.output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(srt);

    const full_output_path = std.fs.cwd().realpathAlloc(allocator, opts.output_path) catch |err| blk: {
        // Fall back to the original path if resolving an absolute path fails.
        std.debug.print("Warning: failed to resolve absolute output path: {s}\n", .{@errorName(err)});
        const dup = allocator.dupe(u8, opts.output_path) catch {
            // If even this fails, just print the original path slice and return.
            progress.printSummary(opts.output_path);
            return;
        };
        break :blk dup;
    };
    defer allocator.free(full_output_path);

    progress.printSummary(full_output_path);
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
