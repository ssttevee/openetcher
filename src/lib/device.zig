const std = @import("std");
const builtin = @import("builtin");

const contract = @import("contract.zig");

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

    /// Length of a buffer that can carry `max_len` bytes to `target_io.writeAt`,
    /// including room to zero-pad the tail to the write alignment.
    pub fn writeBufferLength(self: @This(), max_len: usize) error{ InvalidBlockSize, Overflow }!usize {
        const alignment = try checkedAlignment(self.write_alignment);
        return std.math.add(usize, max_len, alignment - 1) catch error.Overflow;
    }

    /// Length of the scratch buffer `target_io.readAt` needs for reads of up
    /// to `max_len` bytes: the request rounded out to alignment at both ends,
    /// plus slack to align the buffer address itself.
    pub fn readScratchLength(self: @This(), max_len: usize) error{ InvalidBlockSize, Overflow }!usize {
        const alignment = try checkedAlignment(self.read_alignment);
        return std.math.add(usize, max_len, 3 * alignment) catch error.Overflow;
    }

    fn checkedAlignment(alignment: u32) error{InvalidBlockSize}!usize {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidBlockSize;
        return alignment;
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
    else => |os| @compileError("openetcher has no device backend for " ++ @tagName(os)),
};

comptime {
    validatePlatform(platform);
}

/// Checks a platform backend against the contract every backend implements.
/// Only the selected backend is compiled, so this is what keeps the others
/// honest when `scripts/test-targets.sh` builds for their targets.
fn validatePlatform(comptime P: type) void {
    const Allocator = std.mem.Allocator;
    const Io = std.Io;
    contract.expectFn(P, "probeTarget", &.{ Allocator, Io, []const u8 }, TargetInfo);
    contract.expectFn(P, "openTarget", &.{ Allocator, Io, []const u8 }, OpenTarget);
    contract.expectFn(P, "prepareTargetPath", &.{ Allocator, Io, []const u8 }, void);
    contract.expectFn(P, "prepareTarget", &.{ Allocator, Io, *OpenTarget }, void);
    contract.expectFn(P, "listCandidateDisks", &.{ Allocator, Io, ListOptions }, CandidateDiskList);
    contract.expectFn(P, "resolveDiskId", &.{ Allocator, Io, []const u8, ResolveDiskIdOptions }, []u8);
    contract.expectFn(P, "lookupDiskByPath", &.{ Allocator, Io, []const u8, LookupDiskOptions }, ?CandidateDisk);

    contract.expectDecls(P, "device backend", &.{"target_io"});
    const T = P.target_io;
    contract.expectDecls(T, "target I/O backend", &.{"supports_devices"});
    _ = @as(bool, T.supports_devices);
    contract.expectFn(T, "writeAt", &.{ Io, *OpenTarget, []u8, usize, u64 }, void);
    contract.expectFn(T, "readAt", &.{ Io, *OpenTarget, []u8, u64, []u8 }, usize);
    contract.expectFn(T, "sync", &.{ Io, *OpenTarget }, void);
}

pub const probeTarget = platform.probeTarget;
pub const openTarget = platform.openTarget;
pub const prepareTargetPath = platform.prepareTargetPath;
pub const prepareTarget = platform.prepareTarget;
pub const listCandidateDisks = platform.listCandidateDisks;
pub const resolveDiskId = platform.resolveDiskId;
pub const lookupDiskByPath = platform.lookupDiskByPath;
/// Platform-provided target operations, chosen at compile time. The flash
/// engine calls only `writeAt`, `readAt`, and `sync`; alignment, padding, and
/// syscall strategy live in each platform backend. Callers supply every
/// buffer, sized with `TargetCapabilities.writeBufferLength` and
/// `readScratchLength`, so the backends never allocate.
pub const target_io = platform.target_io;
