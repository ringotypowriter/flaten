const std = @import("std");

pub const CliOptions = struct {
    input_path: []const u8,
    output_path: []const u8,
    sample_rate: u32 = 16_000,
    min_speech_ms: u32 = 300,
    min_silence_ms: u32 = 200,
};

pub const ParseError = error{
    MissingInput,
    MissingValue,
    UnknownFlag,
};

/// Parse CLI flags (without argv[0]).
/// Returns owned strings allocated from the provided allocator.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var sample_rate: u32 = 16_000;
    var min_speech_ms: u32 = 300;
    var min_silence_ms: u32 = 200;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            input_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            output_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--sample-rate")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sample_rate = try parseUnsigned(args[i]);
        } else if (std.mem.eql(u8, arg, "--min-speech-ms")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            min_speech_ms = try parseUnsigned(args[i]);
        } else if (std.mem.eql(u8, arg, "--min-silence-ms")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            min_silence_ms = try parseUnsigned(args[i]);
        } else {
            return ParseError.UnknownFlag;
        }
    }

    if (input_path == null) return ParseError.MissingInput;

    const final_input = input_path.?;
    const final_output = if (output_path) |out|
        out
    else
        try defaultOutputPath(allocator, final_input);

    return CliOptions{
        .input_path = final_input,
        .output_path = final_output,
        .sample_rate = sample_rate,
        .min_speech_ms = min_speech_ms,
        .min_silence_ms = min_silence_ms,
    };
}

fn parseUnsigned(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 10) catch ParseError.MissingValue;
}

fn defaultOutputPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    const stem = std.fs.path.stem(input_path);
    // If stem is empty (unlikely), fall back to entire input name.
    const base = if (stem.len == 0) input_path else stem;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    var writer = buf.writer();
    try writer.print("{s}.srt", .{base});
    return buf.toOwnedSlice();
}

test "parse minimal args produces default output" {
    const gpa = std.testing.allocator;
    const opts = try parse(gpa, &.{ "--input", "video.mp4" });
    defer gpa.free(opts.input_path);
    defer gpa.free(opts.output_path);

    try std.testing.expectEqualStrings("video.mp4", opts.input_path);
    try std.testing.expectEqualStrings("video.srt", opts.output_path);
    try std.testing.expect(opts.sample_rate == 16_000);
}

test "parse overrides output and sample rate" {
    var gpa = std.testing.allocator;
    const opts = try parse(gpa, &.{
        "-i",               "a.mov",
        "-o",               "out/sub.srt",
        "--sample-rate",    "8000",
        "--min-speech-ms",  "500",
        "--min-silence-ms", "300",
    });
    defer gpa.free(opts.input_path);
    defer gpa.free(opts.output_path);

    try std.testing.expectEqualStrings("a.mov", opts.input_path);
    try std.testing.expectEqualStrings("out/sub.srt", opts.output_path);
    try std.testing.expectEqual(@as(u32, 8000), opts.sample_rate);
    try std.testing.expectEqual(@as(u32, 500), opts.min_speech_ms);
    try std.testing.expectEqual(@as(u32, 300), opts.min_silence_ms);
}

test "missing input errors" {
    try std.testing.expectError(ParseError.MissingInput, parse(std.testing.allocator, &.{}));
}

test "unknown flag errors" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(std.testing.allocator, &.{"--weird"}));
}

test "missing value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(std.testing.allocator, &.{"--input"}));
    try std.testing.expectError(ParseError.MissingValue, parse(std.testing.allocator, &.{"--sample-rate"}));
}
