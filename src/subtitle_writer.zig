const std = @import("std");

pub const SubtitleItem = struct {
    /// 1-based index in SRT output
    index: usize,
    /// start time in milliseconds
    start_ms: u64,
    /// end time in milliseconds
    end_ms: u64,
    /// subtitle text, may contain multiple lines
    text: []const u8,
};

/// Format a millisecond timestamp as HH:MM:SS,mmm required by SRT.
pub fn writeTimestamp(writer: anytype, ms: u64) !void {
    const hours: u64 = ms / 3_600_000;
    const minutes: u64 = (ms % 3_600_000) / 60_000;
    const seconds: u64 = (ms % 60_000) / 1_000;
    const millis: u64 = ms % 1_000;

    try writer.print("{d:0>2}:{d:0>2}:{d:0>2},{d:0>3}", .{ hours, minutes, seconds, millis });
}

/// Build an SRT string from subtitle items. Caller owns the returned buffer.
pub fn formatSrt(allocator: std.mem.Allocator, items: []const SubtitleItem) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    var writer = buf.writer();

    for (items, 0..) |item, idx| {
        // index line
        try writer.print("{d}\n", .{item.index});

        // timestamp line
        try writeTimestamp(writer, item.start_ms);
        try writer.writeAll(" --> ");
        try writeTimestamp(writer, item.end_ms);
        try writer.writeByte('\n');

        // text body
        try writer.print("{s}\n", .{item.text});

        // blank line between entries, including after the last to keep tools happy
        try writer.writeByte('\n');

        // guard: index should be 1-based incremental; keep assert to catch misuse during tests
        std.debug.assert(item.index == idx + 1);
    }

    return buf.toOwnedSlice();
}

test "timestamp formatting covers boundaries" {
    const gpa = std.testing.allocator;

    var buffer = std.array_list.Managed(u8).init(gpa);
    defer buffer.deinit();

    var w = buffer.writer();
    try writeTimestamp(w, 0);
    try std.testing.expectEqualStrings("00:00:00,000", buffer.items);

    buffer.shrinkRetainingCapacity(0);
    w = buffer.writer();
    try writeTimestamp(w, 3_723_004); // 1h 2m 3s 4ms
    try std.testing.expectEqualStrings("01:02:03,004", buffer.items);
}

test "formatSrt emits numbered blocks with blank lines" {
    var gpa = std.testing.allocator;
    const items = [_]SubtitleItem{
        .{ .index = 1, .start_ms = 1_000, .end_ms = 2_500, .text = "Hello" },
        .{ .index = 2, .start_ms = 3_000, .end_ms = 4_000, .text = "World" },
    };

    const srt = try formatSrt(gpa, items[0..]);
    defer gpa.free(srt);

    const expected =
        "1\n" ++
        "00:00:01,000 --> 00:00:02,500\n" ++
        "Hello\n" ++
        "\n" ++
        "2\n" ++
        "00:00:03,000 --> 00:00:04,000\n" ++
        "World\n" ++
        "\n";

    try std.testing.expectEqualStrings(expected, srt);
}

test "multiline text is preserved" {
    var gpa = std.testing.allocator;
    const items = [_]SubtitleItem{
        .{ .index = 1, .start_ms = 0, .end_ms = 1_000, .text = "line1\nline2" },
    };

    const srt = try formatSrt(gpa, items[0..]);
    defer gpa.free(srt);

    const expected = "1\n00:00:00,000 --> 00:00:01,000\nline1\nline2\n\n";
    try std.testing.expectEqualStrings(expected, srt);
}
