const std = @import("std");
const Translator = @import("translate_c").Translator;
const build_zig_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const is_macos = target.result.os.tag == .macos;
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string for release") orelse
        @as([]const u8, build_zig_zon.version);
    const strip = b.option(bool, "strip", "Leave out debug info");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const ghostty_ver = build_zig_zon.dependencies.ghostty.hash;
    options.addOption([]const u8, "ghostty_version", ghostty_ver);

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "cross",
                .module = translator.mod,
            },
        },
    });
    exe_mod.addOptions("build_options", options);

    const dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        // Not redundant: in lib-vt mode emit-xcframework defaults to "xcodebuild
        // on PATH" (true even via the CLT stub), which pulls in the iOS SDK at
        // configure time and breaks builds without full Xcode.
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    if (dep) |d| {
        const vt_mod = d.module("ghostty-vt");
        if (target.result.os.tag == .openbsd) vt_mod.sanitize_c = .off;
        exe_mod.addImport("ghostty-vt", vt_mod);
    }

    // Run
    {
        const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "zmx",
            // .use_llvm = true,
            // .use_lld = !is_macos,
            .root_module = exe_mod,
        });

        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        run_step.dependOn(&run_cmd.step);
    }

    // Test
    {
        const test_step = b.step("test", "Run unit tests");
        const test_module = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "cross",
                    .module = translator.mod,
                },
            },
        });
        test_module.addOptions("build_options", options);
        const test_dep = b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-lib-vt" = true,
            .@"emit-xcframework" = false,
            .@"emit-macos-app" = false,
        });
        test_module.addImport(
            "ghostty-vt",
            test_dep.module("ghostty-vt"),
        );
        const exe_unit_tests = b.addTest(.{
            .root_module = test_module,
            // .use_llvm = true,
            // .use_lld = !is_macos,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    // Fuzz the roaming link's packet parser (design/009). Its own module, with
    // no ghostty, so that the fuzzer builds fast. CI runs it with --fuzz.
    {
        const fuzz_step = b.step("fuzz-link", "Fuzz the link packet parser (use with --fuzz)");
        const fuzz_module = b.createModule(.{
            .root_source_file = b.path("src/link/packet.zig"),
            .target = target,
            .optimize = optimize,
        });
        const fuzz_tests = b.addTest(.{ .root_module = fuzz_module });
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    }

    // Check for LSP integration
    {
        const check = b.step("check", "Check if zmx compiles");
        const exe_check = b.addExecutable(.{
            .name = "zmx",
            .root_module = exe_mod,
        });
        check.dependOn(&exe_check.step);
    }
}
