//! macOS backend. Disks are discovered and unmounted through DiskArbitration,
//! the way Etcher does through drivelist and mountutils, and raw devices are
//! sized with the disk ioctls, so nothing runs `diskutil`.

const std = @import("std");

const device = @import("../../device.zig");
const discovery = @import("../discovery.zig");
const da = @import("macos/disk_arbitration.zig");
const posix_device = @import("posix_device.zig");
const target_io_api = @import("target_io.zig");

pub const target_io = target_io_api.posix;

const backend = posix_device.Backend(struct {
    pub const accepts_character_devices = true;
    pub const geometry = diskGeometry;
    pub const resolvedPath = rawDevicePath;
    pub const unmountDiskAt = unmountDisk;
});

pub const probeTarget = backend.probeTarget;
pub const openTarget = backend.openTarget;
pub const prepareTargetPath = backend.prepareTargetPath;
pub const prepareTarget = backend.prepareTarget;

pub fn enumerateDisks(arena: std.mem.Allocator, io: std.Io) discovery.ListError![]device.CandidateDisk {
    const session = da.DASessionCreate(null) orelse return error.DiskListFailed;
    defer da.CFRelease(session);
    return (try scan(arena, io, session)).items(.disk);
}

/// The whole disk holding `path`, after following symlinks, so that a link
/// to a disk is matched, and refused when protected, as the disk itself.
pub fn wholeDiskPath(arena: std.mem.Allocator, io: std.Io, path: []const u8) error{ Canceled, OutOfMemory }![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return arena.dupe(u8, wholeDiskOf(try canonicalPath(io, path, &buffer)));
}

/// `path` with symlinks resolved, in `buffer`; `path` itself when it does
/// not resolve, as for a node that has gone away.
fn canonicalPath(io: std.Io, path: []const u8, buffer: *[std.Io.Dir.max_path_bytes]u8) error{Canceled}![]const u8 {
    const len = std.Io.Dir.cwd().realPathFile(io, path, buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return path,
    };
    return buffer[0..len];
}

/// For a disk node, `/dev/diskN` or `/dev/rdiskN` with any partition suffix,
/// the node of the whole disk; any other path unchanged.
fn wholeDiskOf(path: []const u8) []const u8 {
    const prefix = if (std.mem.startsWith(u8, path, "/dev/r")) "/dev/r" else "/dev/";
    const name = std.mem.cutPrefix(u8, path, prefix) orelse return path;
    const parent = parentName(name) orelse return path;
    return path[0 .. prefix.len + parent.len];
}

/// The node to write for the device at `path`: for a disk node, or a link
/// to one, the unbuffered `/dev/rdisk` node.
fn rawDevicePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) error{ Canceled, OutOfMemory }![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical = try canonicalPath(io, path, &buffer);
    const name = std.mem.cutPrefix(u8, canonical, "/dev/") orelse return allocator.dupe(u8, canonical);
    if (parentName(name) == null) return allocator.dupe(u8, canonical);
    return rawNodePath(allocator, name);
}

/// `/dev/rdiskN` for the BSD name `diskN`: the unbuffered node, which is
/// much faster for whole-disk writes.
fn rawNodePath(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "/dev/r{s}", .{name});
}

/// `_IOR('d', nr, T)` from `<sys/disk.h>`.
fn diskIoctl(comptime nr: u8, comptime T: type) c_int {
    const ioc_out: u32 = 0x40000000;
    return @bitCast(ioc_out | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, 'd') << 8) | nr);
}

const DKIOCGETBLOCKSIZE = diskIoctl(24, u32);
const DKIOCGETBLOCKCOUNT = diskIoctl(25, u64);

fn diskGeometry(fd: std.posix.fd_t) ?posix_device.Geometry {
    var block_size: u32 = 0;
    var block_count: u64 = 0;
    if (std.c.ioctl(fd, DKIOCGETBLOCKSIZE, &block_size) != 0) return null;
    if (std.c.ioctl(fd, DKIOCGETBLOCKCOUNT, &block_count) != 0) return null;
    if (block_size == 0 or !std.math.isPowerOfTwo(block_size)) return null;
    const size = std.math.mul(u64, block_count, block_size) catch return null;
    return .{ .size = size, .block_size = block_size };
}

/// A whole disk as DiskArbitration describes it. `scan` returns these as a
/// `MultiArrayList`, so the disks are contiguous and `enumerateDisks` can
/// return them without copying.
const Whole = struct {
    name: [:0]const u8,
    disk: device.CandidateDisk,
    /// The index of the physical disk this APFS container's volumes were
    /// credited to, as drivelist's `handleApfs` does.
    folded_into: ?usize,
};

/// A whole disk while `scan` collects its volumes.
const Pending = struct {
    name: [:0]const u8,
    unit: u32,
    description: da.Description,
    location: ?[]const u8,
    media_name: []const u8,
    protocol: []const u8,
    mount_points: std.ArrayList(device.MountPoint) = .empty,
    folded_into: ?usize = null,

    fn lessThan(_: void, a: Pending, b: Pending) bool {
        return a.unit < b.unit;
    }

    /// An APFS container, which appears as a whole disk of its own on top
    /// of the physical disk holding it.
    fn isApfsContainer(self: Pending) bool {
        return std.mem.eql(u8, self.media_name, "AppleAPFSMedia");
    }

    fn isVirtual(self: Pending) bool {
        return std.mem.eql(u8, self.protocol, "Virtual Interface");
    }

    /// Adds the volume DiskArbitration reports mounted on `node`, if any.
    fn addVolume(self: *Pending, arena: std.mem.Allocator, node: da.Dictionary) std.mem.Allocator.Error!void {
        const path = try node.path(arena, da.kDADiskDescriptionVolumePathKey) orelse return;
        try self.mount_points.append(arena, .{
            .path = path,
            .label = try node.string(arena, da.kDADiskDescriptionVolumeNameKey),
        });
    }
};

/// A partition or APFS volume node, such as `disk3s1s1`.
const Partition = struct {
    name: [:0]const u8,
    /// Its whole disk, such as `disk3`.
    whole: []const u8,
};

/// Every whole disk with its mount points, in unit order. Drivelist learns
/// the disk names from DiskArbitration's appeared callbacks within a fixed
/// 50 ms window; reading them from `/dev` finds the same disks without
/// depending on timing.
fn scan(arena: std.mem.Allocator, io: std.Io, session: da.DASessionRef) discovery.ListError!std.MultiArrayList(Whole).Slice {
    var pending: std.ArrayList(Pending) = .empty;
    defer for (pending.items) |whole| whole.description.release();
    var partitions: std.ArrayList(Partition) = .empty;
    {
        var dev = std.Io.Dir.openDirAbsolute(io, "/dev", .{ .iterate = true }) catch |err| return discovery.listFailure(err);
        defer dev.close(io);
        var entries = dev.iterate();
        while (entries.next(io) catch |err| return discovery.listFailure(err)) |entry| {
            const whole_name = parentName(entry.name) orelse continue;
            const name = try arena.dupeSentinel(u8, entry.name, 0);
            if (whole_name.len != name.len) {
                try partitions.append(arena, .{ .name = name, .whole = name[0..whole_name.len] });
                continue;
            }
            const unit = std.fmt.parseInt(u32, name["disk".len..], 10) catch continue;
            const description = copyDescription(session, name) orelse continue;
            // Until it is in `pending`, whose items the outer defer releases.
            errdefer description.release();
            const fields = description.dictionary;
            try pending.append(arena, .{
                .name = name,
                .unit = unit,
                .description = description,
                .location = try fields.string(arena, da.kDADiskDescriptionBusPathKey),
                .media_name = try fields.string(arena, da.kDADiskDescriptionMediaNameKey) orelse "",
                .protocol = try fields.string(arena, da.kDADiskDescriptionDeviceProtocolKey) orelse "",
            });
        }
    }
    std.mem.sort(Pending, pending.items, {}, Pending.lessThan);

    // A volume can sit on the whole disk itself or on any partition of it,
    // including APFS snapshots such as `disk3s1s1`.
    for (pending.items) |*whole| try whole.addVolume(arena, whole.description.dictionary);
    for (partitions.items) |partition| {
        const owner = for (pending.items) |*whole| {
            if (std.mem.eql(u8, whole.name, partition.whole)) break whole;
        } else continue;
        const description = copyDescription(session, partition.name) orelse continue;
        defer description.release();
        try owner.addVolume(arena, description.dictionary);
    }

    // An APFS container's volumes belong to the physical disk behind it,
    // which drivelist finds by a shared bus path.
    for (pending.items) |*container| {
        if (!container.isApfsContainer()) continue;
        const location = container.location orelse continue;
        for (pending.items, 0..) |*physical, index| {
            if (physical.isApfsContainer() or physical.isVirtual()) continue;
            if (!std.mem.eql(u8, physical.location orelse continue, location)) continue;
            try physical.mount_points.appendSlice(arena, container.mount_points.items);
            container.folded_into = index;
            break;
        }
    }

    // One key for every disk's icon lookup, rather than one per disk.
    const icon_file_key = da.CFStringCreateWithCString(null, "IOBundleResourceFile", da.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer da.CFRelease(icon_file_key);

    var wholes: std.MultiArrayList(Whole) = .empty;
    try wholes.ensureTotalCapacity(arena, pending.items.len);
    for (pending.items) |source| {
        wholes.appendAssumeCapacity(.{
            .name = source.name,
            .folded_into = source.folded_into,
            .disk = try describe(arena, source, icon_file_key),
        });
    }
    return wholes.slice();
}

fn copyDescription(session: da.DASessionRef, name: [:0]const u8) ?da.Description {
    const disk = da.DADiskCreateFromBSDName(null, session, name) orelse return null;
    defer da.CFRelease(disk);
    return da.Description.copy(disk);
}

const partition_tables: std.StaticStringMap(device.PartitionTable) = .initComptime(.{
    .{ "GUID_partition_scheme", .gpt },
    .{ "FDisk_partition_scheme", .mbr },
});

/// Protocols drivelist counts as SCSI: anything wired in rather than USB
/// or a card reader.
const scsi_protocols: std.StaticStringMap(void) = .initComptime(.{
    .{"SATA"}, .{"SCSI"}, .{"ATA"}, .{"IDE"}, .{"PCI"},
});

/// Drivelist's `CreateDeviceDescriptorFromDiskDescription`.
fn describe(arena: std.mem.Allocator, whole: Pending, icon_file_key: da.CFStringRef) std.mem.Allocator.Error!device.CandidateDisk {
    const fields = whole.description.dictionary;
    const size = fields.number(da.kDADiskDescriptionMediaSizeKey) orelse 0;
    const block_size: u32 = std.math.cast(u32, fields.number(da.kDADiskDescriptionMediaBlockSizeKey) orelse 512) orelse 512;
    const removable = fields.boolean(da.kDADiskDescriptionMediaRemovableKey);
    const system = fields.boolean(da.kDADiskDescriptionDeviceInternalKey) and !removable;
    const content = try fields.string(arena, da.kDADiskDescriptionMediaContentKey) orelse "";
    const media_path = try fields.string(arena, da.kDADiskDescriptionMediaPathKey) orelse whole.name;
    const device_path = try std.fmt.allocPrint(arena, "/dev/{s}", .{whole.name});
    const mount_points = whole.mount_points.items;

    return .{
        .id = try discovery.diskId(arena, "macos", &.{ whole.protocol, whole.media_name, media_path }, size),
        .device_path = device_path,
        .raw_path = try rawNodePath(arena, whole.name),
        .display_name = try discovery.displayName(arena, device_path, mount_points),
        .description = whole.media_name,
        .bus_type = whole.protocol,
        .location = whole.location,
        .size = size,
        .block_size = block_size,
        .logical_block_size = block_size,
        .partition_table = partition_tables.get(content),
        .protected = discovery.isProtected(system, mount_points),
        .system = system,
        .removable = removable or fields.boolean(da.kDADiskDescriptionMediaEjectableKey),
        .read_only = !fields.boolean(da.kDADiskDescriptionMediaWritableKey),
        .virtual = whole.isVirtual() or whole.folded_into != null,
        .card = try isCard(arena, fields, icon_file_key),
        .usb = std.mem.eql(u8, whole.protocol, "USB"),
        .scsi = scsi_protocols.has(whole.protocol),
        // Drivelist reports RAID only through Windows bus types.
        .raid = false,
        .mount_points = mount_points,
    };
}

/// Built-in SD readers give their media the SD card icon. External readers
/// use the generic removable icon, so drivelist cannot tell them from other
/// USB disks, and neither can this.
fn isCard(arena: std.mem.Allocator, fields: da.Dictionary, icon_file_key: da.CFStringRef) std.mem.Allocator.Error!bool {
    const icon = fields.dictionary(da.kDADiskDescriptionMediaIconKey) orelse return false;
    const file = try icon.string(arena, icon_file_key) orelse return false;
    return std.mem.eql(u8, file, "SD.icns");
}

/// For a BSD disk name, `diskN` for itself or any partition or snapshot of
/// it (`diskNsM`, `diskNsMsK`); null for other names.
fn parentName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "disk")) return null;
    const end = std.mem.indexOfNonePos(u8, name, 4, "0123456789") orelse name.len;
    if (end == 4) return null;
    if (end != name.len and name[end] != 's') return null;
    return name[0..end];
}

/// Unmounts every volume on the disk at `path`, including the volumes of APFS
/// containers synthesized on it, with DiskArbitration's whole-disk forced
/// unmount, as mountutils does for Etcher.
fn unmountDisk(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Only a node in /dev names a disk. Anything else, such as a file that
    // merely shares a disk's name, must not select one to force-unmount.
    const whole_path = try wholeDiskPath(arena, io, path);
    const node = std.mem.cutPrefix(u8, whole_path, "/dev/") orelse return error.UnmountFailed;
    const name = if (std.mem.startsWith(u8, node, "rdisk")) node[1..] else node;

    const session = da.DASessionCreate(null) orelse return error.UnmountFailed;
    defer da.CFRelease(session);
    const wholes = try scan(arena, io, session);
    const names = wholes.items(.name);
    const target = for (names, 0..) |whole_name, index| {
        if (std.mem.eql(u8, whole_name, name)) break index;
    } else return error.UnmountFailed;

    for (names, wholes.items(.folded_into)) |whole_name, folded_into| {
        if (folded_into == target) try unmountWhole(io, session, whole_name);
    }
    try unmountWhole(io, session, names[target]);
}

fn onUnmounted(_: da.DADiskRef, dissenter: ?da.DADissenterRef, context: ?*anyopaque) callconv(.c) void {
    const status: *?da.DAReturn = @ptrCast(@alignCast(context.?));
    status.* = if (dissenter) |d| da.DADissenterGetStatus(d) else .success;
    da.CFRunLoopStop(da.CFRunLoopGetCurrent());
}

/// How long to wait for DiskArbitration to report on an unmount, which waits
/// for every volume's filesystem to flush.
const unmount_timeout_seconds = 30;

fn unmountWhole(io: std.Io, session: da.DASessionRef, name: [:0]const u8) error{ UnmountFailed, AccessDenied, Canceled }!void {
    const disk = da.DADiskCreateFromBSDName(null, session, name) orelse return error.UnmountFailed;
    defer da.CFRelease(disk);

    const run_loop = da.CFRunLoopGetCurrent();
    da.DASessionScheduleWithRunLoop(session, run_loop, da.kCFRunLoopDefaultMode);
    // Unscheduling also keeps a callback that arrives after a cancelation
    // from writing to `status` once this frame is gone: callbacks are only
    // delivered while the session is scheduled.
    defer da.DASessionUnscheduleFromRunLoop(session, run_loop, da.kCFRunLoopDefaultMode);

    var status: ?da.DAReturn = null;
    da.DADiskUnmount(disk, da.kDADiskUnmountOptionWhole | da.kDADiskUnmountOptionForce, onUnmounted, &status);
    // The callback can run before the loop does, so check before each turn;
    // a turn ends at the callback's stop or after half a second. A cancel
    // stops the wait, though not the unmount DiskArbitration has started.
    var turns: usize = 0;
    while (status == null and turns < unmount_timeout_seconds * 2) : (turns += 1) {
        try io.checkCancel();
        _ = da.CFRunLoopRunInMode(da.kCFRunLoopDefaultMode, 0.5, 0);
    }

    switch (status orelse return error.UnmountFailed) {
        .success, .not_mounted => {},
        .not_permitted, .not_privileged => return error.AccessDenied,
        else => return error.UnmountFailed,
    }
}

test "parentName maps partitions and snapshots to their whole disk" {
    try std.testing.expectEqualStrings("disk3", parentName("disk3").?);
    try std.testing.expectEqualStrings("disk3", parentName("disk3s1s1").?);
    try std.testing.expectEqualStrings("disk12", parentName("disk12s2").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parentName("diskutil"));
    try std.testing.expectEqual(@as(?[]const u8, null), parentName("disk"));
    try std.testing.expectEqual(@as(?[]const u8, null), parentName("rdisk3"));
    try std.testing.expectEqual(@as(?[]const u8, null), parentName("disk3x"));
}

test "wholeDiskPath strips partition suffixes from either node" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    // Nodes that do not exist keep their path and still lose the suffix.
    try std.testing.expectEqualStrings("/dev/disk999", try wholeDiskPath(arena.allocator(), io, "/dev/disk999s1"));
    try std.testing.expectEqualStrings("/dev/rdisk999", try wholeDiskPath(arena.allocator(), io, "/dev/rdisk999s2s1"));
    try std.testing.expectEqualStrings("/dev/rdisk999", try wholeDiskPath(arena.allocator(), io, "/dev/rdisk999"));
    try std.testing.expectEqualStrings("image.img", try wholeDiskPath(arena.allocator(), io, "image.img"));
    try std.testing.expectEqualStrings("/dev/diskutil", wholeDiskOf("/dev/diskutil"));
}

test "a symlink to a disk resolves to the disk" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Every Mac has disk0, and resolving a link to it needs no access to it.
    try tmp.dir.symLink(io, "/dev/disk0", "disk", .{});
    try tmp.dir.symLink(io, "/dev/rdisk0", "raw", .{});
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const link = try std.Io.Dir.path.join(arena.allocator(), &.{ dir_path, "disk" });
    const raw_link = try std.Io.Dir.path.join(arena.allocator(), &.{ dir_path, "raw" });

    try std.testing.expectEqualStrings("/dev/disk0", try wholeDiskPath(arena.allocator(), io, link));
    try std.testing.expectEqualStrings("/dev/rdisk0", try wholeDiskPath(arena.allocator(), io, raw_link));
    try std.testing.expectEqualStrings("/dev/rdisk0", try rawDevicePath(arena.allocator(), io, link));
    try std.testing.expectEqualStrings("/dev/rdisk0", try rawDevicePath(arena.allocator(), io, raw_link));
}

test "disk ioctl numbers match <sys/disk.h>" {
    try std.testing.expectEqual(@as(c_int, 0x40046418), DKIOCGETBLOCKSIZE);
    try std.testing.expectEqual(@as(c_int, 0x40086419), DKIOCGETBLOCKCOUNT);
}
