const std = @import("std");

/// 模型管理错误类型。
pub const Error = error{
    DownloadFailed,
};

/// 默认使用的模型信息：zipformer 小型中英双语模型。
/// 链接来源：sherpa-onnx 官方发布的
/// `sherpa-onnx-zipformer-zh-en-2023-11-22` 模型归档。
/// 注意：模型会被统一解压到一个固定目录名下，避免因为模型日期变化导致路径改变。
pub const default_model_archive_url =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-zh-en-2023-11-22.tar.bz2";
/// 固定的模型目录名（相对于 base_dir），与具体模型无关。
/// 以后如果更换模型，只需调整下载 URL 即可，目录仍然是 `sherpa-model/`。
pub const default_model_dir_name = "sherpa-model";
pub const default_model_file = "model.int8.onnx";
pub const default_tokens_file = "tokens.txt";

/// 下载函数签名，用于在测试中注入 fake downloader。
pub const DownloadFn = *const fn (
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    model_dir_name: []const u8,
    ctx: ?*anyopaque,
) anyerror!void;

/// 模型管理配置。
pub const Config = struct {
    /// 若提供，则优先使用该目录（通常来自环境变量 SHERPA_MODEL_DIR）。
    env_model_dir: ?[]const u8 = null,
    /// 模型所在目录名（相对于 base_dir）。
    model_dir_name: []const u8 = default_model_dir_name,
    /// 模型文件名。
    model_file: []const u8 = default_model_file,
    /// tokens 文件名。
    tokens_file: []const u8 = default_tokens_file,
    /// 下载函数。为 null 时使用默认实现（curl + tar）。
    download_fn: ?DownloadFn = null,
    /// 传给下载函数的上下文，测试时可用于标记调用次数等。
    download_ctx: ?*anyopaque = null,
    /// 基础目录，真实运行时应传入当前工作目录 "."。
    base_dir: []const u8 = ".",
};

/// 确保模型目录存在且包含必要文件；若缺失则触发下载。
/// 返回的路径为 UTF-8 字符串，由调用方负责释放。
pub fn ensureModelDir(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    // 1. 优先使用外部指定的模型目录（通常来自环境变量）。
    if (cfg.env_model_dir) |env_dir| {
        return allocator.dupe(u8, env_dir);
    }

    // 2. 否则以 base_dir + model_dir_name 为目标目录。
    const model_dir = try joinPath(allocator, cfg.base_dir, cfg.model_dir_name);
    errdefer allocator.free(model_dir);

    try std.fs.cwd().makePath(model_dir);

    const tokens_path = try joinPath(allocator, model_dir, cfg.tokens_file);
    defer allocator.free(tokens_path);

    // 这里只强制要求 tokens 文件存在，用于判断模型是否已经到位。
    // 具体使用哪些 ONNX 文件由上层（如 asr_sherpa）自行决定。
    if (!fileExists(tokens_path)) {
        const downloader = cfg.download_fn orelse defaultDownloadAndExtract;
        try downloader(allocator, cfg.base_dir, cfg.model_dir_name, cfg.download_ctx);

        if (!fileExists(tokens_path)) {
            return Error.DownloadFailed;
        }
    }

    return model_dir;
}

/// 真实运行时使用：从网络下载并解压预训练模型到 base_dir/model_dir_name。
fn defaultDownloadAndExtract(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    model_dir_name: []const u8,
    ctx: ?*anyopaque,
) !void {
    _ = ctx;

    // 默认下载到 base_dir/model_dir_name，tar 时去掉归档里的最外层目录。
    var cmd_buf = std.array_list.Managed(u8).init(allocator);
    errdefer cmd_buf.deinit();

    try cmd_buf.writer().print(
        "mkdir -p '{s}/{s}' && cd '{s}/{s}' && curl -L '{s}' -o model.tar.bz2 && tar xf model.tar.bz2 --strip-components 1 && rm model.tar.bz2",
        .{ base_dir, model_dir_name, base_dir, model_dir_name, default_model_archive_url },
    );
    const cmd = try cmd_buf.toOwnedSlice();
    defer allocator.free(cmd);
    // cmd_buf 的内存已经被转移给 cmd。

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

            // 在 base/model_dir_name 下创建必要文件。
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
    // ensureModelDir 返回的路径应为 base_dir + "/" + default_model_dir_name。
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

    // 预先创建模型目录和必需文件。
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
