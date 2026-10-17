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

pub const ListOptions = struct {
    include_system: bool = false,
};

pub const MountPoint = struct {
    path: []const u8,
};

pub const CandidateDisk = struct {
    id: []const u8,
    device_path: []const u8,
    raw_path: []const u8,
    display_name: []const u8,
    description: []const u8,
    size: u64,
    protected: bool,
    system: bool,
    removable: bool,
    mount_points: []MountPoint,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.device_path);
        allocator.free(self.raw_path);
        allocator.free(self.display_name);
        allocator.free(self.description);
        for (self.mount_points) |mount_point| allocator.free(mount_point.path);
        allocator.free(self.mount_points);
    }
};

pub const CandidateDiskList = struct {
    items: []CandidateDisk,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ResolveDiskIdOptions = struct {
    include_system: bool = true,
};

pub const LookupDiskOptions = struct {
    include_system: bool = true,
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
pub const listCandidateDisks = platform.listCandidateDisks;
pub const resolveDiskId = platform.resolveDiskId;
pub const lookupDiskByPath = platform.lookupDiskByPath;
/// Platform-provided target operations, chosen at compile time. The flash
/// engine calls only `writeAt`, `readAt`, and `sync`; alignment, padding, and
/// syscall strategy live in each platform backend.
pub const target_io = platform.target_io;
