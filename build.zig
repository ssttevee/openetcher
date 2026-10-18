const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openetcher_mod = b.addModule("openetcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    if (target.result.os.tag == .macos) linkMacosFrameworks(b, openetcher_mod, target);

    const exe = b.addExecutable(.{
        .name = "openetcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openetcher", .module = openetcher_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run openetcher");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = openetcher_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const cli_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    // The GUI renders with Quartz, so it only exists on macOS.
    if (target.result.os.tag == .macos) {
        addGui(b, target, optimize, openetcher_mod, test_step);
    }
}

/// The `openetcher-gui` executable, its `gui` run step and its tests.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    openetcher_mod: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const fabrum_dep = b.dependency("fabrum", .{ .target = target, .optimize = optimize });
    const quartz_dep = b.dependency("fabrum_renderer_quartz", .{ .target = target, .optimize = optimize });
    const fabrum_mod = fabrum_dep.module("fabrum");

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openetcher", .module = openetcher_mod },
            .{ .name = "fabrum", .module = fabrum_mod },
            .{ .name = "fabrum-renderer-quartz", .module = quartz_dep.module("fabrum-renderer-quartz") },
        },
    });
    gui_mod.addCSourceFiles(.{
        .root = b.path("src/app/platform/macos"),
        .files = &.{"shell.m"},
        .language = .objective_c,
        .flags = &.{"-fobjc-arc"},
    });
    gui_mod.linkFramework("AppKit", .{});
    gui_mod.linkFramework("UniformTypeIdentifiers", .{});

    const gui = b.addExecutable(.{
        .name = "openetcher-gui",
        .root_module = gui_mod,
    });
    b.installArtifact(gui);

    const gui_step = b.step("gui", "Build and run the macOS GUI");
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    gui_step.dependOn(&run_gui.step);

    // The interface and its update logic run without a window, against
    // fabrum's heuristic text measurement.
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openetcher", .module = openetcher_mod },
                .{ .name = "fabrum", .module = fabrum_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    const gui_tests = b.addTest(.{ .root_module = gui_mod });
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
}

/// The macOS device backend discovers and unmounts disks through
/// DiskArbitration. Zig finds the SDK's frameworks on its own only for the
/// native target, so other macOS targets, such as x86_64 on Apple silicon,
/// get the SDK's paths from `xcrun`.
fn linkMacosFrameworks(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!target.query.isNative()) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    module.linkFramework("DiskArbitration", .{});
    module.linkFramework("CoreFoundation", .{});
}
