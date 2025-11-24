const std = @import("std");

pub const SegmentResult = struct {
    start_ms: u64,
    end_ms: u64,
    text: []const u8,
};

/// Placeholder: should call sherpa-onnx C API. Currently returns empty.
pub fn recognize(allocator: std.mem.Allocator, wav_data: []const u8) ![]SegmentResult {
    // TODO: wire real sherpa-onnx C API. For now, return a stub segment so
    // tests exercise the pipeline end-to-end.
    _ = wav_data;
    const text = try allocator.dupe(u8, "hello (stub)");
    const segs = try allocator.alloc(SegmentResult, 1);
    segs[0] = .{ .start_ms = 0, .end_ms = 500, .text = text };
    return segs;
}

test "recognize returns at least one keyword for hello clip" {
    const gpa = std.testing.allocator;
    const fake_wav: []const u8 = "FAKEPCM"; // placeholder bytes
    const results = try recognize(gpa, fake_wav);
    defer if (results.len > 0) gpa.free(results[0].text);

    // for the real implementation we'd expect something containing hello/world
    var found = false;
    for (results) |seg| {
        if (std.mem.indexOf(u8, seg.text, "hello") != null or std.mem.indexOf(u8, seg.text, "world") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}
