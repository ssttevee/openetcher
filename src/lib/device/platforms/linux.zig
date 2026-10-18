//! Linux backend. Etcher's drivelist runs `lsblk` and reads
//! `/dev/disk/by-path`; this reads the sources `lsblk` itself reads, sysfs,
//! `/proc/self/mountinfo`, and udev's `/dev/disk` links and database, and
//! applies drivelist's rules to them. Disks are unmounted the way Etcher's
//! mountutils does, with `umount2`.

const std = @import("std");
const linux = std.os.linux;
const fs_path = std.Io.Dir.path;

const device = @import("../../device.zig");
const discovery = @import("../discovery.zig");
const posix_device = @import("posix_device.zig");
const target_io_api = @import("target_io.zig");

pub const target_io = target_io_api.posix;

const backend = posix_device.Backend(struct {
    pub const accepts_character_devices = false;
    pub const geometry = blockGeometry;
    pub const unmountDiskAt = unmountDisk;

    pub fn resolvedPath(allocator: std.mem.Allocator, _: std.Io, path: []const u8) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, path);
    }
});

pub const probeTarget = backend.probeTarget;
pub const openTarget = backend.openTarget;
pub const prepareTargetPath = backend.prepareTargetPath;
pub const prepareTarget = backend.prepareTarget;

const BLKGETSIZE64 = linux.IOCTL.IOR(0x12, 114, usize);
const BLKSSZGET = linux.IOCTL.IO(0x12, 104);

fn blockGeometry(fd: std.posix.fd_t) ?posix_device.Geometry {
    var size: u64 = 0;
    var sector_size: c_int = 0;
    if (linux.errno(linux.ioctl(fd, BLKGETSIZE64, @intFromPtr(&size))) != .SUCCESS) return null;
    if (linux.errno(linux.ioctl(fd, BLKSSZGET, @intFromPtr(&sector_size))) != .SUCCESS) return null;
    const block_size = std.math.cast(u32, sector_size) orelse return null;
    if (block_size == 0 or !std.math.isPowerOfTwo(block_size)) return null;
    return .{ .size = size, .block_size = block_size };
}

pub fn enumerateDisks(arena: std.mem.Allocator, io: std.Io) discovery.ListError![]device.CandidateDisk {
    const sys: Sysfs = .{ .arena = arena, .io = io };
    const mounts = try parseMountInfo(arena, try sys.read("/proc/self/mountinfo", .unlimited) orelse return error.DiskListFailed);
    const labels = try sys.linkTargets("/dev/disk/by-label");
    const locations = try sys.linkTargets("/dev/disk/by-path");

    var names: std.ArrayList([]const u8) = .empty;
    {
        var block = std.Io.Dir.openDirAbsolute(io, "/sys/block", .{ .iterate = true }) catch |err| return discovery.listFailure(err);
        defer block.close(io);
        var entries = block.iterate();
        while (entries.next(io) catch |err| return discovery.listFailure(err)) |entry| {
            // Like drivelist, leave out loop devices, optical drives, and RAM disks.
            if (std.mem.startsWith(u8, entry.name, "loop") or
                std.mem.startsWith(u8, entry.name, "sr") or
                std.mem.startsWith(u8, entry.name, "ram")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var disks: std.ArrayList(device.CandidateDisk) = .empty;
    for (names.items) |name| {
        const disk = try describe(sys, name, mounts, labels, locations) orelse continue;
        try disks.append(arena, disk);
    }
    return disks.items;
}

pub fn wholeDiskPath(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    // Follow links such as /dev/disk/by-id/... to the kernel's node.
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return path,
    };
    if (!std.mem.startsWith(u8, real, "/dev/")) return real;
    const sys: Sysfs = .{ .arena = arena, .io = io };
    const class_path = try std.fmt.allocPrint(arena, "/sys/class/block/{s}", .{real["/dev/".len..]});
    if (!try sys.exists(try std.fmt.allocPrint(arena, "{s}/partition", .{class_path}))) return real;
    // A partition's sysfs directory sits inside its disk's.
    const target = try sys.link(class_path) orelse return real;
    const parent = fs_path.dirname(target) orelse return real;
    return std.fmt.allocPrint(arena, "/dev/{s}", .{fs_path.basename(parent)});
}

/// Sorts a failure to reach something in sysfs, procfs, or udev's files.
/// The errors in `Absent` mean it is not there, which is routine, since
/// attributes vary by kernel, driver, and udev setup; cancelation passes
/// through; anything else means the disk list cannot be trusted. Naming an
/// error in `Absent` that `err` cannot be fails the build, so each caller
/// lists only what its operation reports.
fn absent(err: anytype, comptime Absent: type) error{ Canceled, DiskListFailed }!void {
    inline for (@typeInfo(Absent).error_set.error_names.?) |name| {
        const member: @TypeOf(err) = @field(Absent, name);
        if (err == member) return;
    }
    return discovery.listFailure(err);
}

/// What opening a missing or unreadable directory reports.
const AbsentDir = error{ FileNotFound, NotDir, AccessDenied, PermissionDenied, NoDevice };

/// Reads sysfs, procfs, and udev's files, treating what is missing or
/// unreadable as absent.
const Sysfs = struct {
    arena: std.mem.Allocator,
    io: std.Io,

    /// The contents of `path`, trimmed of trailing whitespace.
    fn read(self: Sysfs, path: []const u8, limit: std.Io.Limit) discovery.ListError!?[]const u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                // Drivers fail reads of attributes they cannot report, such
                // as a detached device's model, with EIO.
                try absent(e, AbsentDir || error{ IsDir, StreamTooLong, InputOutput });
                return null;
            },
        };
        return std.mem.trimEnd(u8, text, " \t\r\n");
    }

    fn attr(self: Sysfs, dir: []const u8, name: []const u8) discovery.ListError!?[]const u8 {
        const text = try self.read(try fs_path.join(self.arena, &.{ dir, name }), .limited(4096)) orelse return null;
        return if (text.len == 0) null else text;
    }

    fn number(self: Sysfs, dir: []const u8, name: []const u8) discovery.ListError!?u64 {
        const text = try self.attr(dir, name) orelse return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    fn exists(self: Sysfs, path: []const u8) error{ Canceled, DiskListFailed }!bool {
        std.Io.Dir.accessAbsolute(self.io, path, .{}) catch |err| {
            try absent(err, error{ FileNotFound, AccessDenied, PermissionDenied });
            return false;
        };
        return true;
    }

    /// The absolute target of the symlink at `path`.
    fn link(self: Sysfs, path: []const u8) discovery.ListError!?[]const u8 {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.readLinkAbsolute(self.io, path, &buffer) catch |err| {
            try absent(err, error{ FileNotFound, NotDir, NotLink, AccessDenied, PermissionDenied });
            return null;
        };
        return try fs_path.resolveAlloc(self.arena, &.{ fs_path.dirname(path) orelse "/", buffer[0..len] });
    }

    /// For a directory of udev links such as `/dev/disk/by-label`, the
    /// kernel name each link points at mapped to the link's decoded name.
    /// Where several links share a target the lowest name wins, so the
    /// choice is stable.
    fn linkTargets(self: Sysfs, dir_path: []const u8) discovery.ListError!std.StringHashMapUnmanaged([]const u8) {
        var map: std.StringHashMapUnmanaged([]const u8) = .empty;
        var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch |err| {
            try absent(err, AbsentDir);
            return map;
        };
        defer dir.close(self.io);
        var entries = dir.iterate();
        while (entries.next(self.io) catch |err| {
            try absent(err, error{ AccessDenied, PermissionDenied });
            return map;
        }) |entry| {
            const link_path = try fs_path.join(self.arena, &.{ dir_path, entry.name });
            const target = try self.link(link_path) orelse continue;
            const name = try decodeUdevName(self.arena, entry.name);
            const slot = try map.getOrPut(self.arena, fs_path.basename(target));
            if (!slot.found_existing or std.mem.lessThan(u8, name, slot.value_ptr.*)) slot.value_ptr.* = name;
        }
        return map;
    }
};

/// Drivelist's lsblk transform for one disk; null when sysfs no longer has
/// it, as when it was unplugged mid-scan.
fn describe(
    sys: Sysfs,
    name: []const u8,
    mounts: []const Mount,
    labels: std.StringHashMapUnmanaged([]const u8),
    locations: std.StringHashMapUnmanaged([]const u8),
) discovery.ListError!?device.CandidateDisk {
    const arena = sys.arena;
    const block_path = try std.fmt.allocPrint(arena, "/sys/block/{s}", .{name});
    const sys_path = try sys.link(block_path) orelse return null;
    const sectors = try sys.number(sys_path, "size") orelse return null;
    const size = std.math.mul(u64, sectors, 512) catch return null;

    const parents = try deviceParents(sys, sys_path);
    // Virtual block devices (device mapper, md, zram) have no parent
    // device, which lsblk reports as the bare subsystem list "block".
    const virtual = parents.subsystems.len == 0;
    const transport = transportOf(name, sys_path, parents.subsystems);

    // Mount points of the disk itself and of each partition, matched by
    // device number, or by source path for filesystems such as btrfs that
    // report an anonymous one.
    var mount_points: std.ArrayList(device.MountPoint) = .empty;
    const members = try partitionsOf(sys, sys_path, name);
    for (members) |member| {
        for (mounts) |mount| {
            if (!member.owns(mount)) continue;
            try mount_points.append(arena, .{ .path = mount.mount_point, .label = labels.get(member.name) });
        }
    }

    const vendor = readable(try sys.attr(sys_path, "device/vendor"));
    const model = readable(try sys.attr(sys_path, "device/model") orelse try sys.attr(sys_path, "device/name"));
    const description = try discovery.joinDescription(arena, labels.get(name), vendor, model, mount_points.items);
    const bus_type = if (transport) |tran| tran.busType() else "UNKNOWN";
    const location = locations.get(name);
    const device_path = try std.fmt.allocPrint(arena, "/dev/{s}", .{name});
    const udev = try udevProperties(sys, members[0].dev);

    const removable = (try sys.number(sys_path, "removable") orelse 0) == 1 or parents.hotplug or virtual;
    const system = !removable and !virtual;
    const physical_block_size = try sys.number(sys_path, "queue/physical_block_size");
    const logical_block_size = try sys.number(sys_path, "queue/logical_block_size");

    return .{
        .id = try discovery.diskId(arena, "linux", &.{ bus_type, vendor orelse "", model orelse "", udev.serial orelse "", location orelse device_path }, size),
        .device_path = device_path,
        .raw_path = device_path,
        .display_name = device_path,
        .description = if (description.len == 0) name else description,
        .bus_type = bus_type,
        .location = if (location) |link_name| try std.fmt.allocPrint(arena, "/dev/disk/by-path/{s}", .{link_name}) else null,
        .size = size,
        .block_size = std.math.cast(u32, physical_block_size orelse 512) orelse 512,
        .logical_block_size = std.math.cast(u32, logical_block_size orelse 512) orelse 512,
        .partition_table = udev.partition_table,
        .protected = discovery.isProtected(system, mount_points.items),
        .system = system,
        .removable = removable,
        .read_only = (try sys.number(sys_path, "ro") orelse 0) == 1,
        .virtual = virtual,
        .card = transport == .mmc,
        .usb = transport == .usb,
        // Of drivelist's SCSI transports (sata, scsi, ata, ide, pci), the
        // kernel paths here only ever identify SATA.
        .scsi = transport == .sata,
        // Drivelist reports RAID only through Windows bus types, so md
        // arrays count as virtual disks rather than RAID members.
        .raid = false,
        .mount_points = mount_points.items,
    };
}

/// Drops bus ids such as virtio's "0x1af4" vendor, which name no product.
fn readable(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (std.mem.startsWith(u8, value, "0x")) null else value;
}

const Parents = struct {
    /// The subsystem of each ancestor device, nearest first.
    subsystems: []const []const u8,
    /// Whether any ancestor is on a hot-pluggable bus or calls itself
    /// removable, as `lsblk` decides HOTPLUG.
    hotplug: bool,
};

fn deviceParents(sys: Sysfs, sys_path: []const u8) discovery.ListError!Parents {
    var subsystems: std.ArrayList([]const u8) = .empty;
    var hotplug = false;
    var dir = fs_path.dirname(sys_path);
    while (dir) |path| : (dir = fs_path.dirname(path)) {
        if (!std.mem.startsWith(u8, path, "/sys/devices/")) break;
        const subsystem = try sys.link(try std.fmt.allocPrint(sys.arena, "{s}/subsystem", .{path})) orelse continue;
        const subsystem_name = fs_path.basename(subsystem);
        try subsystems.append(sys.arena, subsystem_name);
        if (hotplug_buses.has(subsystem_name)) hotplug = true;
        if (try sys.attr(path, "removable")) |removable| {
            if (std.mem.eql(u8, removable, "removable")) hotplug = true;
        }
    }
    return .{ .subsystems = subsystems.items, .hotplug = hotplug };
}

/// Buses whose devices `lsblk` counts as hot-pluggable.
const hotplug_buses: std.StaticStringMap(void) = .initComptime(.{
    .{"usb"}, .{"ieee1394"}, .{"pcmcia"}, .{"mmc"}, .{"ccw"},
});

/// `lsblk`'s TRAN column.
const Transport = enum {
    usb,
    nvme,
    mmc,
    sata,
    sas,
    fc,
    iscsi,
    sbp,
    virtio,

    /// The name upper-cased, as drivelist reports it in `busType`.
    fn busType(self: Transport) []const u8 {
        return switch (self) {
            inline else => |tag| comptime upper: {
                var name: [@tagName(tag).len]u8 = undefined;
                _ = std.ascii.upperString(&name, @tagName(tag));
                const final = name;
                break :upper &final;
            },
        };
    }
};

/// The transport, from the disk's name, its sysfs path, and its
/// ancestors' subsystems; null when none applies.
fn transportOf(name: []const u8, sys_path: []const u8, subsystems: []const []const u8) ?Transport {
    for (subsystems) |subsystem| if (std.mem.eql(u8, subsystem, "usb")) return .usb;
    if (std.mem.startsWith(u8, name, "nvme")) return .nvme;
    if (std.mem.startsWith(u8, name, "mmcblk")) return .mmc;
    const markers = [_]struct { []const u8, Transport }{
        .{ "/ata", .sata },
        .{ "/end_device-", .sas },
        .{ "/rport-", .fc },
        .{ "/session", .iscsi },
        .{ "/fw", .sbp },
    };
    for (markers) |marker| if (std.mem.indexOf(u8, sys_path, marker[0]) != null) return marker[1];
    for (subsystems) |subsystem| if (std.mem.eql(u8, subsystem, "virtio")) return .virtio;
    return null;
}

const DeviceNumber = struct { major: u32, minor: u32 };

/// The disk itself or one of its partitions.
const Member = struct {
    name: []const u8,
    dev: ?DeviceNumber,

    fn owns(self: Member, mount: Mount) bool {
        if (self.dev) |dev| if (dev.major == mount.dev.major and dev.minor == mount.dev.minor) return true;
        return std.mem.startsWith(u8, mount.source, "/dev/") and std.mem.eql(u8, mount.source["/dev/".len..], self.name);
    }
};

/// The disk first, then its partitions, which are the subdirectories of
/// its sysfs directory holding a `partition` attribute.
fn partitionsOf(sys: Sysfs, sys_path: []const u8, name: []const u8) discovery.ListError![]const Member {
    var members: std.ArrayList(Member) = .empty;
    try members.append(sys.arena, .{ .name = name, .dev = try deviceNumber(sys, sys_path) });

    var dir = std.Io.Dir.openDirAbsolute(sys.io, sys_path, .{ .iterate = true }) catch |err| {
        try absent(err, AbsentDir);
        return members.items;
    };
    defer dir.close(sys.io);
    var entries = dir.iterate();
    while (entries.next(sys.io) catch |err| {
        try absent(err, error{ AccessDenied, PermissionDenied });
        return members.items;
    }) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, name)) continue;
        const partition_path = try fs_path.join(sys.arena, &.{ sys_path, entry.name });
        if (try sys.attr(partition_path, "partition") == null) continue;
        try members.append(sys.arena, .{ .name = try sys.arena.dupe(u8, entry.name), .dev = try deviceNumber(sys, partition_path) });
    }
    return members.items;
}

fn deviceNumber(sys: Sysfs, sys_path: []const u8) discovery.ListError!?DeviceNumber {
    return parseDeviceNumber(try sys.attr(sys_path, "dev") orelse return null);
}

fn parseDeviceNumber(text: []const u8) ?DeviceNumber {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    return .{
        .major = std.fmt.parseInt(u32, text[0..colon], 10) catch return null,
        .minor = std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch return null,
    };
}

const UdevProperties = struct {
    partition_table: ?device.PartitionTable = null,
    serial: ?[]const u8 = null,
};

/// What udev recorded about the device in its database, which `lsblk`
/// reads for PTTYPE.
fn udevProperties(sys: Sysfs, dev: ?DeviceNumber) discovery.ListError!UdevProperties {
    const number = dev orelse return .{};
    const path = try std.fmt.allocPrint(sys.arena, "/run/udev/data/b{d}:{d}", .{ number.major, number.minor });
    return parseUdevData(try sys.read(path, .limited(1 << 16)) orelse return .{});
}

const udev_partition_tables: std.StaticStringMap(device.PartitionTable) = .initComptime(.{
    .{ "gpt", .gpt },
    .{ "dos", .mbr },
});

fn parseUdevData(text: []const u8) UdevProperties {
    var properties: UdevProperties = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "E:")) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[2..equals];
        const value = line[equals + 1 ..];
        if (std.mem.eql(u8, key, "ID_PART_TABLE_TYPE")) {
            properties.partition_table = udev_partition_tables.get(value);
        } else if (std.mem.eql(u8, key, "ID_SERIAL")) {
            properties.serial = value;
        }
    }
    return properties;
}

/// udev escapes characters unsafe in file names as `\xNN`.
fn decodeUdevName(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, name, "\\x") == null) return arena.dupe(u8, name);
    var text: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < name.len) {
        if (index + 4 <= name.len and name[index] == '\\' and name[index + 1] == 'x') {
            if (parseByte(name[index + 2 .. index + 4], 16)) |byte| {
                try text.append(arena, byte);
                index += 4;
                continue;
            }
        }
        try text.append(arena, name[index]);
        index += 1;
    }
    return text.items;
}

const Mount = struct {
    dev: DeviceNumber,
    mount_point: []const u8,
    source: []const u8,
};

/// The mounts in `/proc/self/mountinfo`, skipping malformed lines.
fn parseMountInfo(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const Mount {
    var mounts: std.ArrayList(Mount) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // id parent major:minor root mount-point options [optional...] - fstype source super-options
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dev = parseDeviceNumber(fields.next() orelse continue) orelse continue;
        _ = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        while (fields.next()) |field| if (std.mem.eql(u8, field, "-")) break;
        _ = fields.next() orelse continue;
        const source = fields.next() orelse continue;
        try mounts.append(arena, .{
            .dev = dev,
            .mount_point = try decodeMountField(arena, mount_point),
            .source = try decodeMountField(arena, source),
        });
    }
    return mounts.items;
}

/// The kernel escapes space, tab, newline, and backslash in mountinfo as
/// three-digit octal.
fn decodeMountField(arena: std.mem.Allocator, field: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, field, '\\') == null) return field;
    var text: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < field.len) {
        if (field[index] == '\\' and index + 4 <= field.len) {
            if (parseByte(field[index + 1 .. index + 4], 8)) |byte| {
                try text.append(arena, byte);
                index += 4;
                continue;
            }
        }
        try text.append(arena, field[index]);
        index += 1;
    }
    return text.items;
}

/// The byte that `digits` spell in `base`. Unlike `std.fmt.parseInt`, this
/// takes nothing but digits: no sign, and no underscores between them.
fn parseByte(digits: []const u8, base: u8) ?u8 {
    var value: u16 = 0;
    for (digits) |char| value = value * base + (std.fmt.charToDigit(char, base) catch return null);
    return std.math.cast(u8, value);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Unmounts every filesystem on the disk at `path` or its partitions,
/// newest mount first so nested mounts go before their parents. Like
/// mountutils, each mount gets an expiring unmount, retried once, then a
/// lazy detach, then a forced unmount.
fn unmountDisk(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sys: Sysfs = .{ .arena = arena, .io = io };

    const whole_path = try wholeDiskPath(arena, io, path);
    const name = std.mem.cutPrefix(u8, whole_path, "/dev/") orelse return error.UnmountFailed;
    const sys_path = try sys.link(try std.fmt.allocPrint(arena, "/sys/class/block/{s}", .{name})) orelse return error.UnmountFailed;
    const members = try partitionsOf(sys, sys_path, name);
    const mounts = try parseMountInfo(arena, try sys.read("/proc/self/mountinfo", .unlimited) orelse return error.UnmountFailed);

    var failed = false;
    var index = mounts.len;
    while (index > 0) {
        index -= 1;
        const mount = mounts[index];
        for (members) |member| {
            if (member.owns(mount)) break;
        } else continue;
        const mount_point = try arena.dupeSentinel(u8, mount.mount_point, 0);
        unmount(mount_point) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            error.UnmountFailed => failed = true,
        };
    }
    if (failed) return error.UnmountFailed;
}

fn unmount(mount_point: [:0]const u8) error{ AccessDenied, UnmountFailed }!void {
    // The first expiring unmount only marks the mount; the second unmounts
    // it if nothing is using it.
    const attempts = [_]u32{ linux.MNT.EXPIRE, linux.MNT.EXPIRE, linux.MNT.DETACH, linux.MNT.FORCE };
    for (attempts) |flags| {
        switch (linux.errno(linux.umount2(mount_point, flags))) {
            .SUCCESS => return,
            // Already gone, as when a parent's detach took it along.
            .INVAL, .NOENT => return,
            .PERM => return error.AccessDenied,
            else => {},
        }
    }
    return error.UnmountFailed;
}

test "parseMountInfo reads device numbers, paths, and sources" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        "22 1 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw\n" ++
        "40 22 8:17 / /media/user/My\\040Disk rw,nosuid shared:20 master:3 - vfat /dev/sdb1 rw\n" ++
        "41 22 0:45 / /data rw - btrfs /dev/sdc rw\n" ++
        "garbage\n";
    const mounts = try parseMountInfo(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), mounts.len);
    try std.testing.expectEqual(@as(u32, 8), mounts[1].dev.major);
    try std.testing.expectEqual(@as(u32, 17), mounts[1].dev.minor);
    try std.testing.expectEqualStrings("/media/user/My Disk", mounts[1].mount_point);
    try std.testing.expectEqualStrings("/dev/sdb1", mounts[1].source);

    const btrfs: Member = .{ .name = "sdc", .dev = .{ .major = 8, .minor = 32 } };
    try std.testing.expect(btrfs.owns(mounts[2]));
    const sdb1: Member = .{ .name = "sdb1", .dev = .{ .major = 8, .minor = 17 } };
    try std.testing.expect(sdb1.owns(mounts[1]));
    try std.testing.expect(!sdb1.owns(mounts[0]));
}

test "decodeMountField leaves anything but three octal digits alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\\b", try decodeMountField(arena.allocator(), "a\\134b"));
    try std.testing.expectEqualStrings("\\1_2", try decodeMountField(arena.allocator(), "\\1_2"));
    try std.testing.expectEqualStrings("\\+12", try decodeMountField(arena.allocator(), "\\+12"));
    try std.testing.expectEqualStrings("\\400", try decodeMountField(arena.allocator(), "\\400"));
}

test "decodeUdevName undoes udev's hex escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("My Disk", try decodeUdevName(arena.allocator(), "My\\x20Disk"));
    try std.testing.expectEqualStrings("plain", try decodeUdevName(arena.allocator(), "plain"));
    try std.testing.expectEqualStrings("bad\\xZZ", try decodeUdevName(arena.allocator(), "bad\\xZZ"));
    try std.testing.expectEqualStrings("\\x+5", try decodeUdevName(arena.allocator(), "\\x+5"));
    try std.testing.expectEqualStrings("\\x_5", try decodeUdevName(arena.allocator(), "\\x_5"));
}

test "parseUdevData finds the partition table and serial" {
    const properties = parseUdevData("S:disk/by-id/usb-x\nE:ID_SERIAL=SanDisk_Cruzer_123\nE:ID_PART_TABLE_TYPE=dos\n");
    try std.testing.expectEqual(device.PartitionTable.mbr, properties.partition_table.?);
    try std.testing.expectEqualStrings("SanDisk_Cruzer_123", properties.serial.?);
    try std.testing.expectEqual(@as(?device.PartitionTable, null), parseUdevData("E:ID_PART_TABLE_TYPE=atari\n").partition_table);
}

test "transportOf follows lsblk" {
    const usb_path = "/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdb";
    try std.testing.expectEqual(Transport.usb, transportOf("sdb", usb_path, &.{ "scsi", "scsi", "scsi", "usb", "usb", "pci" }).?);
    const sata_path = "/sys/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda";
    try std.testing.expectEqual(Transport.sata, transportOf("sda", sata_path, &.{ "scsi", "scsi", "scsi", "pci" }).?);
    try std.testing.expectEqual(Transport.nvme, transportOf("nvme0n1", "/sys/devices/pci0000:00/0000:00:1d.0/0000:3d:00.0/nvme/nvme0/nvme0n1", &.{ "nvme", "pci" }).?);
    try std.testing.expectEqual(Transport.mmc, transportOf("mmcblk0", "/sys/devices/platform/mmc0/mmc0:0001/block/mmcblk0", &.{"mmc"}).?);
    try std.testing.expectEqual(@as(?Transport, null), transportOf("dm-0", "/sys/devices/virtual/block/dm-0", &.{}));
    try std.testing.expectEqualStrings("NVME", Transport.nvme.busType());
}

test "BLKGETSIZE64 matches the generic ioctl encoding" {
    // On the common architectures; others encode direction bits differently.
    switch (@import("builtin").cpu.arch) {
        .x86_64, .aarch64 => try std.testing.expectEqual(@as(u32, 0x80081272), BLKGETSIZE64),
        else => {},
    }
    try std.testing.expectEqual(@as(u32, 0x1268), BLKSSZGET);
}
