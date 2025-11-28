const std = @import("std");

/// 输出格式类型，目前支持 SRT 和纯文本 txt。
pub const OutputFormat = enum {
    srt,
    txt,
};

pub const CliOptions = struct {
    input_path: []const u8,
    output_path: []const u8,
    /// 输出格式，默认 SRT；可通过 --format 或 --txt 切换。
    format: OutputFormat = .srt,
    sample_rate: u32 = 16_000,
    min_speech_ms: u32 = 300,
    min_silence_ms: u32 = 200,
    asr_num_threads: i32 = 2,
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
    var format: OutputFormat = .srt;
    var sample_rate: u32 = 16_000;
    var min_speech_ms: u32 = 300;
    var min_silence_ms: u32 = 200;
    var asr_num_threads: i32 = 2;

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
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            format = try parseFormat(args[i]);
        } else if (std.mem.eql(u8, arg, "--txt")) {
            // 兼容老参数：等价于 --format txt
            format = .txt;
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
        } else if (std.mem.eql(u8, arg, "--asr-num-threads")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            asr_num_threads = try parseSigned(args[i]);
        } else {
            return ParseError.UnknownFlag;
        }
    }

    if (input_path == null) return ParseError.MissingInput;

    const final_input = input_path.?;
    const final_output = if (output_path) |out|
        out
    else
        try defaultOutputPath(allocator, final_input, format);

    return CliOptions{
        .input_path = final_input,
        .output_path = final_output,
        .format = format,
        .sample_rate = sample_rate,
        .min_speech_ms = min_speech_ms,
        .min_silence_ms = min_silence_ms,
        .asr_num_threads = asr_num_threads,
    };
}

fn parseUnsigned(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 10) catch ParseError.MissingValue;
}

fn parseSigned(text: []const u8) !i32 {
    return std.fmt.parseInt(i32, text, 10) catch ParseError.MissingValue;
}

fn parseFormat(text: []const u8) !OutputFormat {
    if (std.mem.eql(u8, text, "srt")) return .srt;
    if (std.mem.eql(u8, text, "txt")) return .txt;
    return ParseError.MissingValue;
}

fn defaultOutputPath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    format: OutputFormat,
) ![]u8 {
    const stem = std.fs.path.stem(input_path);
    // If stem is empty (unlikely), fall back to entire input name.
    const base = if (stem.len == 0) input_path else stem;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    var writer = buf.writer();
    const ext: []const u8 = switch (format) {
        .srt => "srt",
        .txt => "txt",
    };
    try writer.print("{s}.{s}", .{ base, ext });
    return buf.toOwnedSlice();
}

test "parse minimal args produces default output" {
    const gpa = std.testing.allocator;
    const opts = try parse(gpa, &.{ "--input", "video.mp4" });
    defer gpa.free(opts.input_path);
    defer gpa.free(opts.output_path);

    try std.testing.expectEqualStrings("video.mp4", opts.input_path);
    try std.testing.expectEqualStrings("video.srt", opts.output_path);
    try std.testing.expect(opts.format == .srt);
    try std.testing.expect(opts.sample_rate == 16_000);
}

test "parse overrides output and sample rate" {
    var gpa = std.testing.allocator;
    const opts = try parse(gpa, &.{
        "-i",                 "a.mov",
        "-o",                 "out/sub.srt",
        "--format",           "txt",
        "--sample-rate",      "8000",
        "--min-speech-ms",    "500",
        "--min-silence-ms",   "300",
        "--asr-num-threads",  "4",
    });
    defer gpa.free(opts.input_path);
    defer gpa.free(opts.output_path);

    try std.testing.expectEqualStrings("a.mov", opts.input_path);
    try std.testing.expectEqualStrings("out/sub.srt", opts.output_path);
    try std.testing.expect(opts.format == .txt);
    try std.testing.expectEqual(@as(u32, 8000), opts.sample_rate);
    try std.testing.expectEqual(@as(u32, 500), opts.min_speech_ms);
    try std.testing.expectEqual(@as(u32, 300), opts.min_silence_ms);
    try std.testing.expectEqual(@as(i32, 4), opts.asr_num_threads);
}

test "parse txt flag switches default extension to .txt" {
    const gpa = std.testing.allocator;
    const opts = try parse(gpa, &.{ "--input", "clip.mov", "--txt" });
    defer gpa.free(opts.input_path);
    defer gpa.free(opts.output_path);

    try std.testing.expectEqualStrings("clip.mov", opts.input_path);
    try std.testing.expectEqualStrings("clip.txt", opts.output_path);
    try std.testing.expect(opts.format == .txt);
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
