//! Platform-neutral disk discovery rules, after Etcher: how its scanner
//! (etcher-sdk's block-device adapter) filters and names the drives that
//! drivelist reports, and how a disk's id is derived. Each platform backend
//! gathers the raw facts and uses these to finish a `CandidateDisk`, so the
//! rules agree everywhere and are tested on every host.

const std = @import("std");
const builtin = @import("builtin");

const device = @import("../device.zig");
const CandidateDisk = device.CandidateDisk;
const MountPoint = device.MountPoint;

/// What enumerating disks can fail with, on every platform.
pub const ListError = error{ OutOfMemory, DiskListFailed, Canceled };

/// Maps a failure to read the disk list: cancelation passes through, and
/// anything else means the list is unavailable. `err` keeps its concrete
/// error set, so passing one that cannot be `Canceled` fails the build.
pub fn listFailure(err: anytype) error{ DiskListFailed, Canceled } {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.DiskListFailed,
    };
}

/// Whether `listCandidateDisks` shows `disk` under `options`. Like Etcher,
/// never RAID members, whose flashing has effects beyond the one disk, or
/// disks reporting no size.
pub fn isListed(disk: CandidateDisk, options: device.ListOptions) bool {
    if (disk.raid) return false;
    if (disk.size == 0) return false;
    if (disk.system and !options.include_system) return false;
    if (disk.virtual and !options.include_virtual) return false;
    return true;
}

/// Whether `path` names `disk`. Windows paths are case-insensitive.
pub fn hasPath(disk: CandidateDisk, path: []const u8) bool {
    return pathEql(disk.device_path, path) or pathEql(disk.raw_path, path);
}

fn pathEql(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

/// Etcher's display name: the drive letters of a Windows physical drive that
/// has volumes, otherwise the device path.
pub fn displayName(arena: std.mem.Allocator, device_path: []const u8, mount_points: []const MountPoint) std.mem.Allocator.Error![]const u8 {
    if (mount_points.len == 0 or std.ascii.findIgnoreCase(device_path, "PhysicalDrive") == null) return device_path;
    var text: std.ArrayList(u8) = .empty;
    for (mount_points, 0..) |mount_point, index| {
        if (index != 0) try text.appendSlice(arena, ", ");
        try text.appendSlice(arena, mount_point.path);
    }
    return text.items;
}

/// Whether `flash` refuses the disk without `--force`: a system disk, or
/// one carrying the running system's root filesystem even though the
/// platform calls it removable, as when booted from a USB disk.
pub fn isProtected(system: bool, mount_points: []const MountPoint) bool {
    if (system) return true;
    for (mount_points) |mount_point| if (std.mem.eql(u8, mount_point.path, "/")) return true;
    return false;
}

/// An id like `macos-1a2b...`: a hash of facts that identify the disk and
/// stay put across replugging into the same port and across reboots, unlike
/// the device path, which the OS hands out in discovery order.
pub fn diskId(arena: std.mem.Allocator, prefix: []const u8, facts: []const []const u8, size: u64) std.mem.Allocator.Error![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (facts) |fact| {
        hasher.update(fact);
        hasher.update("\n");
    }
    hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, size)));
    return std.fmt.allocPrint(arena, "{s}-{x}", .{ prefix, hasher.final() });
}

/// Drivelist's description on Linux: the volume label, vendor, and model,
/// then the labels (or paths) of the mounted partitions in parentheses,
/// with runs of whitespace collapsed.
pub fn joinDescription(arena: std.mem.Allocator, label: ?[]const u8, vendor: ?[]const u8, model: ?[]const u8, mount_points: []const MountPoint) std.mem.Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for ([_]?[]const u8{ label, vendor, model }) |part| try appendWords(arena, &text, part orelse "");

    var subs: std.ArrayList([]const u8) = .empty;
    for (mount_points) |mount_point| {
        const sub = mount_point.label orelse mount_point.path;
        for (subs.items) |seen| {
            if (std.mem.eql(u8, seen, sub)) break;
        } else try subs.append(arena, sub);
    }
    if (subs.items.len != 0) {
        try text.appendSlice(arena, if (text.items.len == 0) "(" else " (");
        for (subs.items, 0..) |sub, index| {
            if (index != 0) try text.appendSlice(arena, ", ");
            try text.appendSlice(arena, sub);
        }
        try text.append(arena, ')');
    }
    return text.items;
}

fn appendWords(arena: std.mem.Allocator, text: *std.ArrayList(u8), words: []const u8) std.mem.Allocator.Error!void {
    var it = std.mem.tokenizeAny(u8, words, " \t\r\n");
    while (it.next()) |word| {
        if (text.items.len != 0) try text.append(arena, ' ');
        try text.appendSlice(arena, word);
    }
}

fn testDisk(overrides: anytype) CandidateDisk {
    var disk: CandidateDisk = .{
        .id = "test-1",
        .device_path = "/dev/sdb",
        .raw_path = "/dev/sdb",
        .display_name = "/dev/sdb",
        .description = "",
        .bus_type = "USB",
        .location = null,
        .size = 1 << 30,
        .block_size = 512,
        .logical_block_size = 512,
        .partition_table = null,
        .protected = false,
        .system = false,
        .removable = true,
        .read_only = false,
        .virtual = false,
        .card = false,
        .usb = true,
        .scsi = false,
        .raid = false,
        .mount_points = &.{},
    };
    inline for (comptime std.meta.fieldNames(@TypeOf(overrides))) |name| @field(disk, name) = @field(overrides, name);
    return disk;
}

test "isListed filters like Etcher's scanner" {
    const defaults: device.ListOptions = .{};
    try std.testing.expect(isListed(testDisk(.{}), defaults));
    try std.testing.expect(!isListed(testDisk(.{ .raid = true }), .everything));
    try std.testing.expect(!isListed(testDisk(.{ .size = 0 }), .everything));
    try std.testing.expect(!isListed(testDisk(.{ .system = true }), defaults));
    try std.testing.expect(isListed(testDisk(.{ .system = true }), .{ .include_system = true }));
    try std.testing.expect(!isListed(testDisk(.{ .virtual = true }), .{ .include_system = true }));
    try std.testing.expect(isListed(testDisk(.{ .virtual = true }), .everything));
}

test "displayName lists drive letters only for Windows physical drives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const letters = [_]MountPoint{ .{ .path = "E:\\" }, .{ .path = "F:\\" } };
    try std.testing.expectEqualStrings("E:\\, F:\\", try displayName(arena.allocator(), "\\\\.\\PhysicalDrive2", &letters));
    try std.testing.expectEqualStrings("\\\\.\\PhysicalDrive3", try displayName(arena.allocator(), "\\\\.\\PhysicalDrive3", &.{}));
    try std.testing.expectEqualStrings("/dev/disk4", try displayName(arena.allocator(), "/dev/disk4", &.{.{ .path = "/Volumes/X" }}));
}

test "diskId depends on every fact and the size" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try diskId(arena.allocator(), "linux", &.{ "USB", "SanDisk" }, 100);
    try std.testing.expect(std.mem.startsWith(u8, a, "linux-"));
    try std.testing.expectEqualStrings(a, try diskId(arena.allocator(), "linux", &.{ "USB", "SanDisk" }, 100));
    try std.testing.expect(!std.mem.eql(u8, a, try diskId(arena.allocator(), "linux", &.{ "USB", "SanDisk" }, 101)));
    try std.testing.expect(!std.mem.eql(u8, a, try diskId(arena.allocator(), "linux", &.{ "USBSanDisk", "" }, 100)));
}

test "joinDescription matches drivelist's lsblk description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mounts = [_]MountPoint{
        .{ .path = "/media/boot", .label = "boot" },
        .{ .path = "/media/root" },
        .{ .path = "/media/boot2", .label = "boot" },
    };
    try std.testing.expectEqualStrings(
        "SanDisk Cruzer Blade (boot, /media/root)",
        try joinDescription(arena.allocator(), null, "SanDisk ", "Cruzer   Blade", &mounts),
    );
    try std.testing.expectEqualStrings("", try joinDescription(arena.allocator(), null, null, null, &.{}));
    try std.testing.expectEqualStrings("(/mnt)", try joinDescription(arena.allocator(), null, null, null, &.{.{ .path = "/mnt" }}));
}

test "isProtected covers system disks and the root filesystem" {
    try std.testing.expect(isProtected(true, &.{}));
    try std.testing.expect(isProtected(false, &.{ .{ .path = "/boot" }, .{ .path = "/" } }));
    try std.testing.expect(!isProtected(false, &.{.{ .path = "/media/usb" }}));
}
