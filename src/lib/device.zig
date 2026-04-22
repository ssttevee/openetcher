const std = @import("std");
const builtin = @import("builtin");

pub const TargetKind = enum {
    regular_file,
    block_device,
    character_device,
};

pub const AccessPattern = enum {
    positional,
    seek_and_stream,
};

pub const TargetCapabilities = struct {
    kind: TargetKind,
    size: u64,
    read_alignment: u32,
    write_alignment: u32,
    optimal_io_size: u32,
    access_pattern: AccessPattern,
    supports_verify_reads: bool,

    pub fn isDevice(self: @This()) bool {
        return self.kind == .block_device or self.kind == .character_device;
    }
};

pub const TargetInfo = struct {
    requested_path: []const u8,
    resolved_path: []const u8,
    owns_resolved_path: bool = true,
    capabilities: TargetCapabilities,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.owns_resolved_path) allocator.free(self.resolved_path);
    }
};

pub const OpenTarget = struct {
    file: std.Io.File,
    info: TargetInfo,

    pub fn close(self: *@This(), allocator: std.mem.Allocator, io: std.Io) void {
        self.file.close(io);
        self.info.deinit(allocator);
    }
};

const platform = switch (builtin.target.os.tag) {
    .macos => @import("device/platforms/macos.zig"),
    .linux => @import("device/platforms/linux.zig"),
    .windows => @import("device/platforms/windows.zig"),
    else => @import("device/platforms/linux.zig"),
};

pub const probeTarget = platform.probeTarget;
pub const openTarget = platform.openTarget;
pub const prepareTargetPath = platform.prepareTargetPath;
pub const prepareTarget = platform.prepareTarget;
