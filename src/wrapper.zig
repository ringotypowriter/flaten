const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // 1) Check ffmpeg availability by attempting to run `ffmpeg -version`.
    var probe = std.process.Child.init(&[_][]const u8{ "ffmpeg", "-version" }, allocator);
    probe.stdin_behavior = .Ignore;
    probe.stdout_behavior = .Ignore;
    probe.stderr_behavior = .Ignore;

    probe.spawn() catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("未找到 ffmpeg，请先安装 (例如: brew install ffmpeg)。\n", .{});
                return err;
            },
            else => return err,
        }
    };

    const probe_status = try probe.wait();
    switch (probe_status) {
        .Exited => {}, // OK
        else => {
            std.debug.print("ffmpeg 存在但运行失败，请检查安装。\n", .{});
            return error.FfmpegNotWorking;
        },
    }

    // 2) Resolve the real binary path: same directory as this wrapper.
    const self_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_dir);

    const flaten_path = try std.fs.path.join(allocator, &.{ self_dir, "bin", "flaten-core" });
    defer allocator.free(flaten_path);

    // 3) Rebuild argv: replace argv[0] with flaten, keep rest.
    var argv = try allocator.alloc([]const u8, args.len);
    defer allocator.free(argv);
    argv[0] = flaten_path;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        argv[i] = args[i];
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            std.debug.print("flaten 被信号 {d} 终止\n", .{sig});
            return error.ChildTerminated;
        },
        else => {
            std.debug.print("flaten 以异常状态退出\n", .{});
            return error.ChildTerminated;
        },
    }
}
