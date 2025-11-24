const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("flaten", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "flaten-core",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "flaten" is the name you will use in your source code to
                // import this module (e.g. `@import("flaten")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "flaten", .module = mod },
            },
        }),
    });

    // Discover libraries via pkg-config without hardcoding paths. Users can
    // override with PKG_CONFIG_PATH (e.g. $HOME/.local/sherpa-onnx/install/lib/pkgconfig).
    const libs = &[_][]const u8{
        "avformat",
        "avcodec",
        "avutil",
        "swresample",
    };
    for (libs) |name| {
        exe.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }

    exe.linkLibC();
    exe.linkLibCpp();

    // Bundle sherpa-onnx binaries for macOS (universal2) and Linux x86_64 so
    // users don't need to install them system-wide. We pick a directory based
    // on the target OS.
    const sherpa_root = "third_party/sherpa-onnx/v1.12.17";
    const sherpa_dir = switch (target.result.os.tag) {
        .macos => sherpa_root ++ "/macos-universal",
        .linux => sherpa_root ++ "/linux-x86_64",
        else => sherpa_root ++ "/linux-x86_64", // default to linux build for other Unix-like targets
    };
    const sherpa_include = b.pathJoin(&.{ sherpa_dir, "include" });
    const sherpa_lib = b.pathJoin(&.{ sherpa_dir, "lib" });

    exe.root_module.addIncludePath(b.path(sherpa_include));
    exe.root_module.addLibraryPath(b.path(sherpa_lib));
    exe.root_module.addRPath(b.path(sherpa_lib));
    exe.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    exe.root_module.linkSystemLibrary("onnxruntime", .{});

    const install_sherpa = b.addInstallDirectory(.{
        .source_dir = b.path(sherpa_lib),
        .install_dir = .lib,
        .install_subdir = "sherpa-onnx",
    });
    exe.step.dependOn(&install_sherpa.step);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Wrapper executable: checks ffmpeg availability then forwards to flaten.
    const wrapper = b.addExecutable(.{
        .name = "flaten",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wrapper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wrapper.linkLibC();
    wrapper.linkLibCpp();
    b.installArtifact(wrapper);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    for (libs) |name| {
        mod_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    mod_tests.linkLibC();
    mod_tests.linkLibCpp();
    mod_tests.root_module.addIncludePath(b.path(sherpa_include));
    mod_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    mod_tests.root_module.addRPath(b.path(sherpa_lib));
    mod_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    mod_tests.root_module.linkSystemLibrary("onnxruntime", .{});

    // A run step that will run the test executable for the root library module.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    for (libs) |name| {
        exe_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    exe_tests.linkLibC();
    exe_tests.linkLibCpp();
    exe_tests.root_module.addIncludePath(b.path(sherpa_include));
    exe_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    exe_tests.root_module.addRPath(b.path(sherpa_lib));
    exe_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    exe_tests.root_module.linkSystemLibrary("onnxruntime", .{});

    // A run step that will run the test executable for the CLI root module.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Additional per-module tests so that `zig build test` covers all files
    // under src/ that define test blocks.
    const subtitle_writer_tests = b.addTest(.{
        .name = "subtitle_writer-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/subtitle_writer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        subtitle_writer_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    subtitle_writer_tests.linkLibC();
    subtitle_writer_tests.linkLibCpp();
    subtitle_writer_tests.root_module.addIncludePath(b.path(sherpa_include));
    subtitle_writer_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    subtitle_writer_tests.root_module.addRPath(b.path(sherpa_lib));
    subtitle_writer_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    subtitle_writer_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_subtitle_writer_tests = b.addRunArtifact(subtitle_writer_tests);

    const cli_options_tests = b.addTest(.{
        .name = "cli_options-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_options.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        cli_options_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    cli_options_tests.linkLibC();
    cli_options_tests.linkLibCpp();
    cli_options_tests.root_module.addIncludePath(b.path(sherpa_include));
    cli_options_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    cli_options_tests.root_module.addRPath(b.path(sherpa_lib));
    cli_options_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    cli_options_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_cli_options_tests = b.addRunArtifact(cli_options_tests);

    const audio_segmenter_tests = b.addTest(.{
        .name = "audio_segmenter-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio_segmenter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        audio_segmenter_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    audio_segmenter_tests.linkLibC();
    audio_segmenter_tests.linkLibCpp();
    audio_segmenter_tests.root_module.addIncludePath(b.path(sherpa_include));
    audio_segmenter_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    audio_segmenter_tests.root_module.addRPath(b.path(sherpa_lib));
    audio_segmenter_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    audio_segmenter_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_audio_segmenter_tests = b.addRunArtifact(audio_segmenter_tests);

    const ffmpeg_adapter_tests = b.addTest(.{
        .name = "ffmpeg_adapter-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffmpeg_adapter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        ffmpeg_adapter_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    ffmpeg_adapter_tests.linkLibC();
    ffmpeg_adapter_tests.linkLibCpp();
    ffmpeg_adapter_tests.root_module.addIncludePath(b.path(sherpa_include));
    ffmpeg_adapter_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    ffmpeg_adapter_tests.root_module.addRPath(b.path(sherpa_lib));
    ffmpeg_adapter_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    ffmpeg_adapter_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_ffmpeg_adapter_tests = b.addRunArtifact(ffmpeg_adapter_tests);

    const asr_sherpa_tests = b.addTest(.{
        .name = "asr_sherpa-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asr_sherpa.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        asr_sherpa_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    asr_sherpa_tests.linkLibC();
    asr_sherpa_tests.linkLibCpp();
    asr_sherpa_tests.root_module.addIncludePath(b.path(sherpa_include));
    asr_sherpa_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    asr_sherpa_tests.root_module.addRPath(b.path(sherpa_lib));
    asr_sherpa_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    asr_sherpa_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_asr_sherpa_tests = b.addRunArtifact(asr_sherpa_tests);

    const pipeline_tests = b.addTest(.{
        .name = "pipeline-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pipeline.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        pipeline_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    pipeline_tests.linkLibC();
    pipeline_tests.linkLibCpp();
    pipeline_tests.root_module.addIncludePath(b.path(sherpa_include));
    pipeline_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    pipeline_tests.root_module.addRPath(b.path(sherpa_lib));
    pipeline_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    pipeline_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);

    const model_manager_tests = b.addTest(.{
        .name = "model_manager-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    for (libs) |name| {
        model_manager_tests.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    }
    model_manager_tests.linkLibC();
    model_manager_tests.linkLibCpp();
    model_manager_tests.root_module.addIncludePath(b.path(sherpa_include));
    model_manager_tests.root_module.addLibraryPath(b.path(sherpa_lib));
    model_manager_tests.root_module.addRPath(b.path(sherpa_lib));
    model_manager_tests.root_module.linkSystemLibrary("sherpa-onnx-c-api", .{});
    model_manager_tests.root_module.linkSystemLibrary("onnxruntime", .{});
    const run_model_manager_tests = b.addRunArtifact(model_manager_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since these run steps do not depend on one another, this will
    // make all of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_subtitle_writer_tests.step);
    test_step.dependOn(&run_cli_options_tests.step);
    test_step.dependOn(&run_audio_segmenter_tests.step);
    test_step.dependOn(&run_ffmpeg_adapter_tests.step);
    test_step.dependOn(&run_asr_sherpa_tests.step);
    test_step.dependOn(&run_pipeline_tests.step);
    test_step.dependOn(&run_model_manager_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
