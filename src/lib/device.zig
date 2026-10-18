const std = @import("std");
const builtin = @import("builtin");

const contract = @import("contract.zig");
const discovery = @import("device/discovery.zig");

pub const TargetKind = enum {
    regular_file,
    block_device,
    character_device,
};

pub const AccessPattern = enum {
    /// Every transfer carries its own offset, so several can be in flight.
    /// The POSIX backend serves regular files and raw devices this way.
    positional,
    /// Transfers share the file position; for a backend whose targets
    /// cannot do positional I/O.
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

    /// Transfer size for a requested `block_size`, rounded up to the write
    /// alignment. Chunks then start on aligned offsets whenever their range
    /// does, which raw devices require of every positional write.
    pub fn chunkLength(self: @This(), block_size: usize) error{ InvalidBlockSize, Overflow }!usize {
        const alignment = try checkedAlignment(self.write_alignment);
        if (block_size == 0) return error.InvalidBlockSize;
        const padded = std.math.add(usize, block_size, alignment - 1) catch return error.Overflow;
        return std.mem.alignBackward(usize, padded, alignment);
    }

    /// Whether a write may start at `offset`.
    pub fn isWriteAligned(self: @This(), offset: u64) bool {
        return self.write_alignment <= 1 or offset % self.write_alignment == 0;
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

/// Which disks `listCandidateDisks` returns. The defaults match what Etcher
/// offers as targets: removable and external disks.
pub const ListOptions = struct {
    /// Include system disks: internal fixed disks, and on Windows the disks
    /// holding the system folders.
    include_system: bool = false,
    /// Include virtual disks: disk images, RAM disks, and on macOS the APFS
    /// containers synthesized on top of a physical disk.
    include_virtual: bool = false,

    /// Every disk the platform reports, for resolving a user's choice.
    pub const everything: ListOptions = .{ .include_system = true, .include_virtual = true };
};

pub const MountPoint = struct {
    path: []const u8,
    /// The volume name, when the platform reports one.
    label: ?[]const u8 = null,
};

pub const PartitionTable = enum { mbr, gpt };

/// A whole disk as discovered by the platform, with the fields Etcher's
/// drivelist reports.
pub const CandidateDisk = struct {
    /// Stable identifier for `--disk-id`, hashed from where the disk attaches
    /// and what it is.
    id: []const u8,
    /// The disk's node in the OS's block layer.
    device_path: []const u8,
    /// The node for unbuffered I/O: `/dev/rdiskN` on macOS, otherwise the
    /// same as `device_path`.
    raw_path: []const u8,
    /// What to call the disk: its mount points on Windows, else its path.
    display_name: []const u8,
    description: []const u8,
    /// The transport, as the platform names it, such as "USB" or "SATA".
    bus_type: []const u8,
    /// Where the disk attaches: the IOKit bus path on macOS, the
    /// `/dev/disk/by-path` link on Linux, the device interface path on
    /// Windows. Null when the platform does not say.
    location: ?[]const u8,
    size: u64,
    /// Physical sector size.
    block_size: u32,
    logical_block_size: u32,
    partition_table: ?PartitionTable,
    /// Whether `flash` refuses the disk without `--force`: a system disk, or
    /// one holding the root filesystem.
    protected: bool,
    system: bool,
    removable: bool,
    read_only: bool,
    virtual: bool,
    /// An SD or MMC card.
    card: bool,
    usb: bool,
    /// Attached through SCSI, SATA, ATA, IDE, or PCI rather than USB or a card
    /// reader.
    scsi: bool,
    /// A RAID set. Only Windows reports these, through the adapter's bus
    /// type, as drivelist does; `listCandidateDisks` never lists them.
    raid: bool,
    mount_points: []const MountPoint,
};

/// Disks with the arena that holds every string and slice in them.
pub const CandidateDiskList = struct {
    arena: std.heap.ArenaAllocator.State,
    items: []const CandidateDisk,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.arena.promote(allocator).deinit();
    }
};

/// One disk with the arena that holds it.
pub const OwnedCandidateDisk = struct {
    arena: std.heap.ArenaAllocator.State,
    disk: CandidateDisk,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.arena.promote(allocator).deinit();
    }
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
    // Every whole disk, allocated in an arena the caller frees wholesale.
    contract.expectFn(P, "enumerateDisks", &.{ Allocator, Io }, []CandidateDisk);
    // The whole disk holding the partition at a path, or the path itself.
    contract.expectFn(P, "wholeDiskPath", &.{ Allocator, Io, []const u8 }, []const u8);

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
/// Platform-provided target operations, chosen at compile time. The flash
/// engine calls only `writeAt`, `readAt`, and `sync`; alignment, padding, and
/// syscall strategy live in each platform backend. Callers supply every
/// buffer, sized with `TargetCapabilities.writeBufferLength` and
/// `readScratchLength`, so the backends never allocate. Every transfer goes
/// through the caller's `std.Io` with its own offset, so transfers are
/// cancelable and calls for disjoint chunks may run concurrently.
pub const target_io = platform.target_io;

const EnumerateError = contract.ErrorSetOf(platform.enumerateDisks);

/// The disks `options` selects, filtered as Etcher's scanner filters
/// drivelist's output.
pub fn listCandidateDisks(allocator: std.mem.Allocator, io: std.Io, options: ListOptions) EnumerateError!CandidateDiskList {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const disks = try platform.enumerateDisks(arena.allocator(), io);

    // Filter in place: the arena owns the slice either way.
    var kept: usize = 0;
    for (disks) |disk| {
        if (!discovery.isListed(disk, options)) continue;
        disks[kept] = disk;
        kept += 1;
    }
    return .{ .arena = arena.state, .items = disks[0..kept] };
}

/// The disk listed with `disk_id`. Callers get the whole disk rather than
/// just its path so that they can check it, such as for `protected`,
/// against the same scan that matched the id.
pub fn resolveDiskId(allocator: std.mem.Allocator, io: std.Io, disk_id: []const u8, options: ListOptions) (EnumerateError || error{ UnknownDiskId, AmbiguousDiskId })!OwnedCandidateDisk {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const disks = try platform.enumerateDisks(arena.allocator(), io);

    var match: ?CandidateDisk = null;
    for (disks) |disk| {
        if (!discovery.isListed(disk, options) or !std.mem.eql(u8, disk.id, disk_id)) continue;
        if (match != null) return error.AmbiguousDiskId;
        match = disk;
    }
    return .{ .arena = arena.state, .disk = match orelse return error.UnknownDiskId };
}

/// The disk at `path`, or the disk holding the partition at `path`; null
/// when `path` is not a listed disk, such as a regular file.
pub fn lookupDiskByPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: ListOptions) EnumerateError!?OwnedCandidateDisk {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const disks = try platform.enumerateDisks(arena.allocator(), io);
    // Some backends' `wholeDiskPath` cannot fail; coercing to an error
    // union lets one `try` serve them all.
    const whole_path = try @as(EnumerateError![]const u8, platform.wholeDiskPath(arena.allocator(), io, path));

    for (disks) |disk| {
        if (discovery.isListed(disk, options) and discovery.hasPath(disk, whole_path)) {
            return .{ .arena = arena.state, .disk = disk };
        }
    }
    arena.deinit();
    return null;
}
