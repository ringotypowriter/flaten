const std = @import("std");

/// Model management error types.
pub const Error = error{
    DownloadFailed,
};

/// Default model metadata: the Zipformer small Chinese-English bilingual model.
/// Source: the official sherpa-onnx release `sherpa-onnx-zipformer-zh-en-2023-11-22`.
/// Note: the model is always extracted into a fixed directory name to keep paths stable across updates.
pub const default_model_archive_url =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-zh-en-2023-11-22.tar.bz2";
/// Fixed model directory name (relative to base_dir), independent of which actual model is used.
/// Future model swaps only require updating the download URL; the directory remains `sherpa-model/`.
pub const default_model_dir_name = "sherpa-model";
pub const default_model_file = "model.int8.onnx";
pub const default_tokens_file = "tokens.txt";

/// Downloader function signature, enabling tests to inject fake downloaders.
pub const DownloadFn = *const fn (
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    model_dir_name: []const u8,
    ctx: ?*anyopaque,
) anyerror!void;

/// Model management configuration.
pub const Config = struct {
    /// If provided, this directory is preferred (typically supplied via SHERPA_MODEL_DIR).
    env_model_dir: ?[]const u8 = null,
    /// Model directory name (relative to base_dir).
    model_dir_name: []const u8 = default_model_dir_name,
    /// Model filename.
    model_file: []const u8 = default_model_file,
    /// Tokens filename.
    tokens_file: []const u8 = default_tokens_file,
    /// Downloader function. When null, the default curl + tar implementation is used.
    download_fn: ?DownloadFn = null,
    /// Context passed to the downloader, useful for counting calls in tests.
    download_ctx: ?*anyopaque = null,
    /// Base directory; real runs should pass the current working directory ".".
    base_dir: []const u8 = ".",
};

/// Ensure the model directory exists and contains required files; download if a file is missing.
/// Returns a UTF-8 string path that the caller is responsible for freeing.
pub fn ensureModelDir(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    // 1. Prefer an externally specified model directory (usually provided via an environment variable).
    if (cfg.env_model_dir) |env_dir| {
        return allocator.dupe(u8, env_dir);
    }

    // 2. Otherwise build base_dir + model_dir_name as the target directory.
    const model_dir = try joinPath(allocator, cfg.base_dir, cfg.model_dir_name);
    errdefer allocator.free(model_dir);

    try std.fs.cwd().makePath(model_dir);

    const tokens_path = try joinPath(allocator, model_dir, cfg.tokens_file);
    defer allocator.free(tokens_path);

    // Only the tokens file is enforced here, which signals that the model is ready.
    // Higher-level modules (e.g., asr_sherpa) decide which ONNX files to use.
    if (!fileExists(tokens_path)) {
        const downloader = cfg.download_fn orelse defaultDownloadAndExtract;
        try downloader(allocator, cfg.base_dir, cfg.model_dir_name, cfg.download_ctx);

        if (!fileExists(tokens_path)) {
            return Error.DownloadFailed;
        }
    }

    return model_dir;
}

/// Used in real runs: download and extract the pretrained model from the network to base_dir/model_dir_name.
fn defaultDownloadAndExtract(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    model_dir_name: []const u8,
    ctx: ?*anyopaque,
) !void {
    _ = ctx;

    // Default behavior: download into base_dir/model_dir_name and strip the outermost directory from the archive when extracting.
    var cmd_buf = std.array_list.Managed(u8).init(allocator);
    errdefer cmd_buf.deinit();

    try cmd_buf.writer().print(
        "mkdir -p '{s}/{s}' && cd '{s}/{s}' && curl -L '{s}' -o model.tar.bz2 && tar xf model.tar.bz2 --strip-components 1 && rm model.tar.bz2",
        .{ base_dir, model_dir_name, base_dir, model_dir_name, default_model_archive_url },
    );
    const cmd = try cmd_buf.toOwnedSlice();
    defer allocator.free(cmd);
    // cmd_buf's memory has been transferred to cmd.

    var child = std.process.Child.init(&.{ "sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    defer if (child.term == null) {
        _ = child.kill() catch {};
    };

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return Error.DownloadFailed;
        },
        else => return Error.DownloadFailed,
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn joinPath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();
    try list.writer().print("{s}/{s}", .{ a, b });
    return list.toOwnedSlice();
}

test "ensureModelDir uses env_model_dir when provided" {
    const gpa = std.testing.allocator;

    var called: bool = false;
    const Downloader = struct {
        fn run(
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            ctx: ?*anyopaque,
        ) anyerror!void {
            if (ctx) |p| {
                const flag: *bool = @ptrCast(@alignCast(p));
                flag.* = true;
            }
        }
    };

    const cfg = Config{
        .env_model_dir = "env-model-dir",
        .download_fn = Downloader.run,
        .download_ctx = &called,
        .base_dir = "ignored",
    };

    const dir = try ensureModelDir(gpa, cfg);
    defer gpa.free(dir);

    try std.testing.expectEqualStrings("env-model-dir", dir);
    try std.testing.expect(!called);
}

test "ensureModelDir triggers download when files missing" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_dir);

    var called: bool = false;
    const Downloader = struct {
        fn run(
            allocator: std.mem.Allocator,
            base: []const u8,
            model_dir_name: []const u8,
            ctx: ?*anyopaque,
        ) anyerror!void {
            if (ctx) |p| {
                const flag: *bool = @ptrCast(@alignCast(p));
                flag.* = true;
            }

            // Create the required files under base/model_dir_name.
            var dir = try std.fs.cwd().openDir(base, .{ .iterate = true });
            defer dir.close();

            try dir.makePath(model_dir_name);

            const model_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_dir_name, default_model_file });
            defer allocator.free(model_path);
            const tokens_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_dir_name, default_tokens_file });
            defer allocator.free(tokens_path);

            {
                var f = try dir.createFile(model_path, .{ .read = true });
                f.close();
            }
            {
                var f = try dir.createFile(tokens_path, .{ .read = true });
                f.close();
            }
        }
    };

    const cfg = Config{
        .env_model_dir = null,
        .download_fn = Downloader.run,
        .download_ctx = &called,
        .base_dir = base_dir,
    };

    const dir_path = try ensureModelDir(gpa, cfg);
    defer gpa.free(dir_path);

    try std.testing.expect(called);
    // ensureModelDir should return base_dir + "/" + default_model_dir_name.
    const expected_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, default_model_dir_name });
    defer gpa.free(expected_dir);
    try std.testing.expectEqualStrings(expected_dir, dir_path);
}

test "ensureModelDir skips download when files already exist" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_dir = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_dir);

    // Pre-create the model directory and required files.
    var root = try std.fs.cwd().openDir(base_dir, .{ .iterate = true });
    defer root.close();

    try root.makePath(default_model_dir_name);

    const model_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ default_model_dir_name, default_model_file });
    defer gpa.free(model_rel);
    const tokens_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ default_model_dir_name, default_tokens_file });
    defer gpa.free(tokens_rel);

    {
        var f = try root.createFile(model_rel, .{ .read = true });
        f.close();
    }
    {
        var f = try root.createFile(tokens_rel, .{ .read = true });
        f.close();
    }

    var called: bool = false;
    const Downloader = struct {
        fn run(
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            ctx: ?*anyopaque,
        ) anyerror!void {
            if (ctx) |p| {
                const flag: *bool = @ptrCast(@alignCast(p));
                flag.* = true;
            }
        }
    };

    const cfg = Config{
        .env_model_dir = null,
        .download_fn = Downloader.run,
        .download_ctx = &called,
        .base_dir = base_dir,
    };

    const dir_path = try ensureModelDir(gpa, cfg);
    defer gpa.free(dir_path);

    const expected_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, default_model_dir_name });
    defer gpa.free(expected_dir);

    try std.testing.expectEqualStrings(expected_dir, dir_path);
    try std.testing.expect(!called);
}
