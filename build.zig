const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openetcher_mod = b.addModule("openetcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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

/// The GUI's tests.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    openetcher_mod: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const fabrum_dep = b.dependency("fabrum", .{ .target = target, .optimize = optimize });
    const fabrum_mod = fabrum_dep.module("fabrum");

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
}
