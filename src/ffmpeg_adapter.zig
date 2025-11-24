const std = @import("std");

pub const FfmpegArgs = struct {
    input_path: []const u8,
    sample_rate: u32 = 16_000,
    mono: bool = true,
};

/// Return argv vector for spawning ffmpeg that writes raw PCM s16le to stdout.
pub fn build_ffmpeg_cmd(args: FfmpegArgs, allocator: std.mem.Allocator) ![][]const u8 {
    _ = allocator; // we use the page allocator to avoid tying lifetimes to caller

    // Construct argv for piping raw PCM s16le to stdout.
    var list = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer list.deinit();

    try list.append("ffmpeg");
    try list.append("-hide_banner");
    try list.append("-loglevel");
    try list.append("error");

    try list.append("-i");
    try list.append(try std.heap.page_allocator.dupe(u8, args.input_path));

    try list.append("-vn"); // drop video

    try list.append("-ac");
    const channels = if (args.mono) "1" else "2";
    try list.append(channels);

    try list.append("-ar");
    const rate_str = try std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.sample_rate});
    try list.append(rate_str);

    try list.append("-f");
    try list.append("s16le");

    try list.append("-acodec");
    try list.append("pcm_s16le");

    try list.append("-"); // stdout

    return try list.toOwnedSlice();
}

test "build_ffmpeg_cmd includes essential flags" {
    const gpa = std.testing.allocator;
    const cmd = try build_ffmpeg_cmd(.{ .input_path = "video.mp4", .sample_rate = 16_000, .mono = true }, gpa);
    defer {
        // allocated buffers will be freed once implemented; currently empty
    }

    // Expect substrings regardless of order
    const joined = std.mem.join(gpa, " ", cmd) catch "";
    defer if (joined.len > 0) gpa.free(joined);

    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "ffmpeg"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "-i"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "video.mp4"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "-ar"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "16000"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "-ac"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "-f"));
    try std.testing.expect(std.mem.containsAtLeast(u8, joined, 1, "s16le"));
}
