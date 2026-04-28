const std = @import("std");

const regular_file = @import("regular_file.zig");
const device = @import("../../device.zig");

const ListDisk = struct {
    id: []const u8,
    device_path: []const u8,
    raw_path: []const u8,
    description: []const u8,
    size: u64,
    protected: bool,
    system: bool,
    removable: bool,
    mount_points: []device.MountPoint,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.device_path);
        allocator.free(self.raw_path);
        allocator.free(self.description);
        for (self.mount_points) |mount_point| allocator.free(mount_point.path);
        allocator.free(self.mount_points);
    }
};

pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false }) catch {
        return regular_file.probeTarget(allocator, io, path);
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind == .file) return regular_file.probeTarget(allocator, io, path);
    if (stat.kind != .block_device and stat.kind != .character_device) return error.UnsupportedTargetType;

    const resolved_path = try resolveDevicePath(allocator, path);
    errdefer allocator.free(resolved_path);

    const size = (try macosDiskSize(allocator, io, resolved_path)) orelse return error.UnsupportedTargetType;
    const kind = if (stat.kind == .block_device) device.TargetKind.block_device else device.TargetKind.character_device;

    return .{
        .requested_path = path,
        .resolved_path = resolved_path,
        .capabilities = .{
            .kind = kind,
            .size = size,
            .read_alignment = 512,
            .write_alignment = 512,
            .optimal_io_size = 1024 * 1024,
            .access_pattern = .seek_and_stream,
            .supports_verify_reads = true,
        },
    };
}

pub fn openTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.OpenTarget {
    const info = try probeTarget(allocator, io, path);
    errdefer info.deinit(allocator);

    return .{
        .file = try std.Io.Dir.cwd().openFile(io, info.resolved_path, .{ .mode = .read_write, .allow_directory = false }),
        .info = info,
    };
}

pub fn prepareTargetPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const info = try probeTarget(allocator, io, path);
    defer info.deinit(allocator);
    if (!info.capabilities.isDevice()) return;
    try unmountDisk(allocator, io, info.resolved_path);
}

pub fn prepareTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget) !void {
    if (!target.info.capabilities.isDevice()) return;
    try unmountDisk(allocator, io, target.info.resolved_path);
}

pub fn listCandidateDisks(allocator: std.mem.Allocator, io: std.Io, options: device.ListOptions) !device.CandidateDiskList {
    const argv: []const []const u8 = if (options.include_system)
        &.{ "diskutil", "list", "physical" }
    else
        &.{ "diskutil", "list", "external", "physical" };

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.DiskListFailed,
        else => return error.DiskListFailed,
    }

    var identifiers: std.ArrayList([]const u8) = .empty;
    defer identifiers.deinit(allocator);
    try parseDiskIdentifiers(allocator, &identifiers, result.stdout);

    var disks: std.ArrayList(device.CandidateDisk) = .empty;
    errdefer {
        for (disks.items) |disk| disk.deinit(allocator);
        disks.deinit(allocator);
    }

    for (identifiers.items) |identifier| {
        defer allocator.free(identifier);

        const disk = try queryDisk(allocator, io, identifier);
        errdefer disk.deinit(allocator);
        if (!options.include_system and disk.system) {
            disk.deinit(allocator);
            continue;
        }

        try disks.append(allocator, .{
            .id = disk.id,
            .device_path = disk.device_path,
            .raw_path = disk.raw_path,
            .display_name = try allocator.dupe(u8, disk.device_path),
            .description = disk.description,
            .size = disk.size,
            .protected = disk.protected,
            .system = disk.system,
            .removable = disk.removable,
            .mount_points = disk.mount_points,
        });
    }

    return .{ .items = try disks.toOwnedSlice(allocator) };
}

pub fn resolveDiskId(allocator: std.mem.Allocator, io: std.Io, disk_id: []const u8, options: device.ResolveDiskIdOptions) ![]u8 {
    const disks = try listCandidateDisks(allocator, io, .{ .include_system = options.include_system });
    defer disks.deinit(allocator);

    var match: ?[]const u8 = null;
    for (disks.items) |disk| {
        if (!std.mem.eql(u8, disk.id, disk_id)) continue;
        if (match != null) return error.AmbiguousDiskId;
        match = disk.device_path;
    }

    const resolved = match orelse return error.UnknownDiskId;
    return allocator.dupe(u8, resolved);
}

pub fn lookupDiskByPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: device.LookupDiskOptions) !?device.CandidateDisk {
    const disks = try listCandidateDisks(allocator, io, .{ .include_system = options.include_system });
    defer disks.deinit(allocator);

    const canonical_path = canonicalDiskPath(allocator, path) catch return null;
    defer allocator.free(canonical_path);

    const raw_path = if (std.mem.startsWith(u8, canonical_path, "/dev/disk"))
        try std.fmt.allocPrint(allocator, "/dev/r{s}", .{canonical_path[5..]})
    else
        try allocator.dupe(u8, canonical_path);
    defer allocator.free(raw_path);

    for (disks.items) |disk| {
        if (!std.mem.eql(u8, disk.device_path, canonical_path) and !std.mem.eql(u8, disk.raw_path, raw_path)) continue;

        return .{
            .id = try allocator.dupe(u8, disk.id),
            .device_path = try allocator.dupe(u8, disk.device_path),
            .raw_path = try allocator.dupe(u8, disk.raw_path),
            .display_name = try allocator.dupe(u8, disk.display_name),
            .description = try allocator.dupe(u8, disk.description),
            .size = disk.size,
            .protected = disk.protected,
            .system = disk.system,
            .removable = disk.removable,
            .mount_points = try dupMountPoints(allocator, disk.mount_points),
        };
    }

    return null;
}

fn resolveDevicePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "/dev/disk")) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "/dev/r{s}", .{path[5..]});
}

fn macosDiskSize(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?u64 {
    if (!std.mem.startsWith(u8, path, "/dev/")) return null;

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "diskutil", "info", path },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(0),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return parseDiskutilSize(result.stdout);
}

fn unmountDisk(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const whole_disk_path = canonicalDiskPath(allocator, path) catch return error.UnmountFailed;
    defer allocator.free(whole_disk_path);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "diskutil", "unmountDisk", whole_disk_path },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.UnmountFailed,
        else => return error.UnmountFailed,
    }
}

fn canonicalDiskPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "/dev/rdisk")) {
        return std.fmt.allocPrint(allocator, "/dev/disk{s}", .{path[10..]});
    }
    if (std.mem.startsWith(u8, path, "/dev/disk")) {
        return allocator.dupe(u8, path);
    }
    return error.UnsupportedTargetType;
}

fn parseDiskutilSize(output: []const u8) ?u64 {
    const marker = "Disk Size:";
    const marker_index = std.mem.indexOf(u8, output, marker) orelse return null;
    const tail = output[marker_index + marker.len ..];
    const open_paren = std.mem.indexOfScalar(u8, tail, '(') orelse return null;
    const after_open = tail[open_paren + 1 ..];
    const close_paren = std.mem.indexOfScalar(u8, after_open, ')') orelse return null;
    const paren_text = after_open[0..close_paren];
    const space_index = std.mem.indexOfScalar(u8, paren_text, ' ') orelse return null;
    const bytes_text = std.mem.trim(u8, paren_text[0..space_index], " ");
    return std.fmt.parseInt(u64, bytes_text, 10) catch null;
}

fn parseDiskIdentifiers(allocator: std.mem.Allocator, identifiers: *std.ArrayList([]const u8), output: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "/dev/disk")) continue;
        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        try identifiers.append(allocator, try allocator.dupe(u8, trimmed[0..end]));
    }
}

fn queryDisk(allocator: std.mem.Allocator, io: std.Io, device_path: []const u8) !ListDisk {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "diskutil", "info", device_path },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.DiskListFailed,
        else => return error.DiskListFailed,
    }

    return parseDiskInfo(allocator, device_path, result.stdout);
}

fn parseDiskInfo(allocator: std.mem.Allocator, fallback_device_path: []const u8, output: []const u8) !ListDisk {
    const device_path = try allocator.dupe(u8, fieldValue(output, "Device Node:") orelse fallback_device_path);
    errdefer allocator.free(device_path);

    const raw_path = if (std.mem.startsWith(u8, device_path, "/dev/disk"))
        try std.fmt.allocPrint(allocator, "/dev/r{s}", .{device_path[5..]})
    else
        try allocator.dupe(u8, device_path);
    errdefer allocator.free(raw_path);

    const description = try allocator.dupe(u8, fieldValue(output, "Device / Media Name:") orelse fieldValue(output, "Media Name:") orelse "unknown");
    errdefer allocator.free(description);

    const size = parseDiskutilSize(output) orelse return error.DiskListFailed;
    const location = fieldValue(output, "Device Location:") orelse "Unknown";
    const removable_media = fieldValue(output, "Removable Media:") orelse "Unknown";
    const os_installable = fieldValue(output, "OS Can Be Installed:") orelse "No";
    const protocol = fieldValue(output, "Protocol:") orelse "Unknown";
    const media_name = fieldValue(output, "Media Name:") orelse description;
    const tree_path = fieldValue(output, "DeviceTreePath:") orelse fieldValue(output, "Device Tree Path:") orelse "unknown-path";

    var mount_points: std.ArrayList(device.MountPoint) = .empty;
    errdefer {
        for (mount_points.items) |mount_point| allocator.free(mount_point.path);
        mount_points.deinit(allocator);
    }

    const disk_id = try makeDiskId(allocator, protocol, media_name, size, tree_path);
    errdefer allocator.free(disk_id);

    if (fieldValue(output, "Mount Point:")) |mount_point| {
        if (!std.mem.eql(u8, mount_point, "Not applicable (no file system)") and mount_point.len != 0) {
            try mount_points.append(allocator, .{ .path = try allocator.dupe(u8, mount_point) });
        }
    }

    return .{
        .id = disk_id,
        .device_path = device_path,
        .raw_path = raw_path,
        .description = description,
        .size = size,
        .protected = std.mem.eql(u8, location, "Internal") or std.mem.eql(u8, os_installable, "Yes"),
        .system = std.mem.eql(u8, location, "Internal") or std.mem.eql(u8, os_installable, "Yes"),
        .removable = std.mem.eql(u8, removable_media, "Removable"),
        .mount_points = try mount_points.toOwnedSlice(allocator),
    };
}

fn fieldValue(output: []const u8, label: []const u8) ?[]const u8 {
    const marker_index = std.mem.indexOf(u8, output, label) orelse return null;
    const tail = output[marker_index + label.len ..];
    const newline_index = std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
    return std.mem.trim(u8, tail[0..newline_index], " \t\r");
}

fn makeDiskId(allocator: std.mem.Allocator, protocol: []const u8, media_name: []const u8, size: u64, tree_path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(protocol);
    hasher.update("\n");
    hasher.update(media_name);
    hasher.update("\n");
    hasher.update(tree_path);
    hasher.update("\n");

    var size_buffer: [20]u8 = undefined;
    const size_text = try std.fmt.bufPrint(&size_buffer, "{}", .{size});
    hasher.update(size_text);

    return std.fmt.allocPrint(allocator, "macos-{x}", .{hasher.final()});
}

fn dupMountPoints(allocator: std.mem.Allocator, mount_points: []const device.MountPoint) ![]device.MountPoint {
    var duplicate = try allocator.alloc(device.MountPoint, mount_points.len);
    var initialized: usize = 0;
    errdefer {
        for (duplicate[0..initialized]) |mount_point| {
            allocator.free(mount_point.path);
        }
        allocator.free(duplicate);
    }

    for (mount_points, 0..) |mount_point, index| {
        duplicate[index] = .{ .path = try allocator.dupe(u8, mount_point.path) };
        initialized += 1;
    }

    return duplicate;
}

test "parseDiskutilSize reads byte count" {
    const sample =
        "   Disk Size:                 63.9 GB (63864569856 Bytes) (exactly 124735488 512-Byte-Units)\n";

    try std.testing.expectEqual(@as(?u64, 63864569856), parseDiskutilSize(sample));
}

test "parseDiskIdentifiers finds whole disks" {
    const sample =
        "/dev/disk0 (internal, physical):\n" ++
        "   #: TYPE NAME SIZE IDENTIFIER\n" ++
        "/dev/disk3 (external, physical):\n";

    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |item| std.testing.allocator.free(item);
        list.deinit(std.testing.allocator);
    }

    try parseDiskIdentifiers(std.testing.allocator, &list, sample);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("/dev/disk0", list.items[0]);
    try std.testing.expectEqualStrings("/dev/disk3", list.items[1]);
}

test "parseDiskInfo marks internal disks as system" {
    const sample =
        "   Device Node:               /dev/disk0\n" ++
        "   Device / Media Name:       APPLE SSD AP1024R\n" ++
        "   Media Name:                APPLE SSD AP1024R\n" ++
        "   Protocol:                  Apple Fabric\n" ++
        "   DeviceTreePath:            IODeviceTree:/internal/ssd0\n" ++
        "   OS Can Be Installed:       No\n" ++
        "   Disk Size:                 1.0 TB (1000555581440 Bytes) (exactly 1954210120 512-Byte-Units)\n" ++
        "   Device Location:           Internal\n" ++
        "   Removable Media:           Fixed\n";

    const disk = try parseDiskInfo(std.testing.allocator, "/dev/disk0", sample);
    defer disk.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/dev/disk0", disk.device_path);
    try std.testing.expectEqualStrings("/dev/rdisk0", disk.raw_path);
    try std.testing.expectEqualStrings("APPLE SSD AP1024R", disk.description);
    try std.testing.expect(std.mem.startsWith(u8, disk.id, "macos-"));
    try std.testing.expectEqual(@as(u64, 1000555581440), disk.size);
    try std.testing.expect(disk.system);
    try std.testing.expect(!disk.removable);
    try std.testing.expectEqual(@as(usize, 0), disk.mount_points.len);
}

test "parseDiskInfo keeps external mounted disks" {
    const sample =
        "   Device Node:               /dev/disk4\n" ++
        "   Device / Media Name:       USB Flash Disk\n" ++
        "   Media Name:                USB Flash Disk\n" ++
        "   Protocol:                  USB\n" ++
        "   DeviceTreePath:            IODeviceTree:/arm-io/usb/path-1\n" ++
        "   Mount Point:               /Volumes/UNTITLED\n" ++
        "   OS Can Be Installed:       No\n" ++
        "   Disk Size:                 31.9 GB (31914983424 Bytes) (exactly 62333952 512-Byte-Units)\n" ++
        "   Device Location:           External\n" ++
        "   Removable Media:           Removable\n";

    const disk = try parseDiskInfo(std.testing.allocator, "/dev/disk4", sample);
    defer disk.deinit(std.testing.allocator);

    try std.testing.expect(!disk.system);
    try std.testing.expect(disk.removable);
    try std.testing.expect(std.mem.startsWith(u8, disk.id, "macos-"));
    try std.testing.expectEqual(@as(usize, 1), disk.mount_points.len);
    try std.testing.expectEqualStrings("/Volumes/UNTITLED", disk.mount_points[0].path);
}
