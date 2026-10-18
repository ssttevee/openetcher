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
