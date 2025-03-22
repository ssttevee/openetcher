const std = @import("std");
const drivelist = @import("../drivelist.zig");
const objc = @import("../macos/objc.zig");

const c = @cImport({
    @cInclude("DiskArbitration/DiskArbitration.h");
    // @cInclude("Foundation/Foundation.h");
});

const CFRunLoop = objc.ExternalClass(
    "CFRunLoop",
    struct {},
);

const NSRunLoop = objc.ExternalClass(
    "NSRunLoop",
    struct {
        pub fn currentRunLoop() NSRunLoop {
            return NSRunLoop.class().msgSend(NSRunLoop, "currentRunLoop", .{});
        }

        pub fn getCFRunLoop(self: NSRunLoop) CFRunLoop {
            return self.msgSend(CFRunLoop, "getCFRunLoop", .{});
        }
    },
);

const NSArray = objc.ExternalClass(
    "NSArray",
    struct {
        pub fn arrayWithObjects(objects: []const @import("objc").Object) NSArray {
            return NSArray.class().msgSend(NSArray, "arrayWithObjects:count:", .{ objects.ptr, objects.len });
        }

        pub fn count(self: NSArray) u32 {
            return self.msgSend(u32, "count", .{});
        }

        pub fn objectAt(self: NSArray, T: type, index: u32) T {
            return self.msgSend(T, "objectAtIndex:", .{index});
        }
    },
);

const NSFileManager = objc.ExternalClass(
    "NSFileManager",
    struct {
        pub fn defaultManager() NSFileManager {
            return NSFileManager.class().msgSend(NSFileManager, "defaultManager", .{});
        }

        pub fn mountedVolumeURLsIncludingResourceValuesForKeys(self: NSFileManager, keys: NSArray) NSArray {
            return self.msgSend(NSArray, "mountedVolumeURLsIncludingResourceValuesForKeys:options:", .{ keys, 0 });
        }
    },
);

const NSURL = objc.ExternalClass(
    "NSURL",
    struct {
        pub fn getResourceValue(self: NSURL, key: NSString) ?*anyopaque {
            var out: ?*anyopaque = undefined;
            self.msgSend(void, "getResourceValue:forKey:error:", .{ &out, key, null });
            return out;
        }

        pub fn path(self: NSURL) NSString {
            return self.msgSend(NSString, "path", .{});
        }
    },
);

/// returns true if the name matches the regex pattern /^disk\d+s\d+/
fn isDiskPartition(bsd_name: []const u8) bool {
    if (bsd_name.len < 4 or !std.mem.eql(u8, bsd_name[0..4], "disk")) {
        return false;
    }

    const s_pos = std.mem.indexOfNonePos(u8, bsd_name, 4, "0123456789") orelse {
        return false;
    };

    if (s_pos == 4) {
        return false;
    }

    if (bsd_name[s_pos] != 's') {
        return false;
    }

    if (bsd_name.len <= s_pos + 1) {
        return false;
    }

    if (std.mem.indexOfNonePos(u8, bsd_name, s_pos + 1, "0123456789")) |pos| {
        if (pos == s_pos + 1) {
            return false;
        }
    }

    return true;
}

test isDiskPartition {
    try std.testing.expect(isDiskPartition("disk1s1"));
    try std.testing.expect(isDiskPartition("disk1s11"));
    try std.testing.expect(isDiskPartition("disk1s111"));
    try std.testing.expect(isDiskPartition("disk11s11"));
    try std.testing.expect(isDiskPartition("disk11s1"));
    try std.testing.expect(isDiskPartition("disk111s1"));
    try std.testing.expect(isDiskPartition("disk1s1s1"));
    try std.testing.expect(isDiskPartition("disk1s1f"));
    try std.testing.expect(!isDiskPartition("dask1s1"));
    try std.testing.expect(!isDiskPartition("disk"));
    try std.testing.expect(!isDiskPartition("disks1"));
    try std.testing.expect(!isDiskPartition("disk1f"));
    try std.testing.expect(!isDiskPartition("disk1s"));
    try std.testing.expect(!isDiskPartition("disk1sf"));
}

const NSString = objc.ExternalClass(
    "NSString",
    struct {
        pub fn UTF8String(self: NSString) [*c]const u8 {
            return self.msgSend([*c]const u8, "UTF8String", .{});
        }
    },
);

fn convertString(ptr: ?*const anyopaque) ?[]const u8 {
    if (@intFromPtr(ptr) % @alignOf(@import("objc").c.id) != 0) {
        return null;
    }

    const cstr = (NSString{
        .object = .{
            .value = @constCast(@alignCast(@ptrCast(ptr orelse return null))),
        },
    }).UTF8String();
    return std.mem.span(cstr);
}

const NSNumber = objc.ExternalClass(
    "NSNumber",
    struct {
        pub fn boolValue(self: NSNumber) bool {
            return self.msgSend(bool, "boolValue", .{});
        }

        pub fn unsignedIntValue(self: NSNumber) u32 {
            return self.msgSend(u32, "unsignedIntValue", .{});
        }
    },
);

fn convertBool(ptr: ?*const anyopaque) bool {
    return (NSNumber{
        .object = .{
            .value = @constCast(@alignCast(@ptrCast(ptr orelse return false))),
        },
    }).boolValue();
}

fn convertNumber(ptr: ?*const anyopaque) u32 {
    if (@intFromPtr(ptr) % 8 != 0) {
        return 0;
    }

    // std.debug.print("convertNumber {*} {d}\n", .{ ptr, @as(*const u8, @alignCast(@ptrCast(ptr orelse return 0))).* });
    return (NSNumber{
        .object = .{
            .value = @constCast(@alignCast(@ptrCast(ptr orelse return 0))),
        },
    }).unsignedIntValue();
}

fn convertDescriptor(allocator: std.mem.Allocator, bsd_name: []const u8, description: c.CFDictionaryRef) !drivelist.DeviceDescriptor {
    const device_protocol = convertString(c.CFDictionaryGetValue(description, c.kDADiskDescriptionDeviceProtocolKey));
    const block_size = convertNumber(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaBlockSizeKey));
    const is_internal = convertBool(c.CFDictionaryGetValue(description, c.kDADiskDescriptionDeviceInternalKey));
    const is_removable = convertBool(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaRemovableKey));
    const is_ejectable = convertBool(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaEjectableKey));
    const media_content = convertString(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaContentKey));

    const bus_type = blk: {
        break :blk try allocator.dupe(u8, device_protocol orelse break :blk null);
    };
    errdefer if (bus_type) |t| allocator.free(t);

    const device = try std.fmt.allocPrint(allocator, "/dev/{s}", .{bsd_name});
    errdefer allocator.free(device);

    const device_path = blk: {
        break :blk try allocator.dupe(u8, convertString(c.CFDictionaryGetValue(description, c.kDADiskDescriptionBusPathKey)) orelse break :blk null);
    };
    errdefer if (device_path) |path| allocator.free(path);

    const raw = try std.fmt.allocPrint(allocator, "/dev/r{s}", .{bsd_name});
    errdefer allocator.free(raw);

    const media_name = blk: {
        break :blk try allocator.dupe(u8, convertString(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaNameKey)) orelse break :blk null);
    };
    errdefer if (media_name) |desc| allocator.free(desc);

    return .{
        .enumerator = .device_arbitration,
        .partition_table_type = if (media_content) |s| if (std.mem.eql(u8, s, "GUID_partition_scheme")) .gpt else if (std.mem.eql(u8, s, "FDisk_partition_scheme")) .mbr else .none else .none,
        .bus_type = bus_type,
        .device = device,
        .device_path = device_path,
        .raw = raw,
        .description = media_name,
        .block_size = block_size,
        .logical_block_size = block_size,
        .size = convertNumber(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaSizeKey)),
        .is_read_only = !convertBool(c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaWritableKey)),
        .is_system = is_internal and !is_removable,
        .is_virtual = if (device_protocol) |s| std.mem.eql(u8, s, "Virtual Interface") else false,
        .is_removable = is_removable or is_ejectable,
        .is_card = blk: {
            // https://github.com/balena-io-modules/drivelist/blob/a616aa9875956ecf1a546cf1d2480ff281e54d2b/src/darwin/list.mm#L31

            const media_icon_dict = c.CFDictionaryGetValue(description, c.kDADiskDescriptionMediaIconKey) orelse break :blk false;

            const icon_file_name_key = c.CFStringCreateWithCString(null, "IOBundleResourceFile", c.kCFStringEncodingUTF8);
            defer c.CFRelease(icon_file_name_key);

            break :blk std.mem.eql(u8, convertString(c.CFDictionaryGetValue(@ptrCast(media_icon_dict), icon_file_name_key)) orelse break :blk false, "SD.icns");
        },
        .is_scsi = blk: {
            if (device_protocol) |s| {
                inline for (.{ "SATA", "SCSI", "ATA", "IDE", "PCI" }) |scsi_type| {
                    if (std.mem.eql(u8, s, scsi_type)) {
                        break :blk true;
                    }
                }
            }

            break :blk false;
        },
        .is_usb = if (device_protocol) |s| std.mem.eql(u8, s, "USB") else false,
    };
}

extern const NSDefaultRunLoopMode: c.CFRunLoopMode;
extern const NSURLVolumeNameKey: NSString;
extern const NSURLVolumeLocalizedNameKey: NSString;

pub fn listDeviceNames(allocator: std.mem.Allocator, session: *c.struct___DASession) ![]const []const u8 {
    var bsd_names: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (bsd_names.items) |bsd_name| {
            allocator.free(bsd_name);
        }

        bsd_names.deinit(allocator);
    }

    const AppendDiskContext = struct {
        allocator: std.mem.Allocator,
        bsd_names: *std.ArrayListUnmanaged([]const u8),

        fn appendDisk(disk: c.DADiskRef, context: ?*anyopaque) callconv(.c) void {
            const ctx: *const @This() = @alignCast(@ptrCast(context));

            const bsd_name = c.DADiskGetBSDName(disk);
            if (bsd_name == null) {
                return;
            }

            ctx.bsd_names.append(ctx.allocator, ctx.allocator.dupe(u8, std.mem.span(bsd_name)) catch unreachable) catch unreachable;
        }
    };

    const ctx = AppendDiskContext{ .allocator = allocator, .bsd_names = &bsd_names };

    c.DARegisterDiskAppearedCallback(session, null, &AppendDiskContext.appendDisk, @constCast(@ptrCast(&ctx)));
    defer c.DAUnregisterCallback(session, @constCast(@ptrCast(&AppendDiskContext.appendDisk)), @constCast(@ptrCast(&ctx)));

    const run_loop = NSRunLoop.currentRunLoop().getCFRunLoop();
    c.DASessionScheduleWithRunLoop(session, @ptrCast(run_loop.object.value), c.kCFRunLoopDefaultMode);
    c.CFRunLoopStop(@ptrCast(run_loop.object.value));
    _ = c.CFRunLoopRunInMode(NSDefaultRunLoopMode, 0.05, 0);

    return bsd_names.toOwnedSlice(allocator);
}

pub fn listStorageDevices(allocator: std.mem.Allocator) ![]drivelist.DeviceDescriptor {
    const session = c.DASessionCreate(c.kCFAllocatorDefault) orelse return error.OutOfMemory;
    defer c.CFRelease(session);

    const bsd_names = try listDeviceNames(allocator, session);
    defer {
        for (bsd_names) |bsd_name| {
            allocator.free(bsd_name);
        }

        allocator.free(bsd_names);
    }

    var devices: std.StringArrayHashMapUnmanaged(drivelist.DeviceDescriptor) = .{};
    defer devices.deinit(allocator);
    errdefer {
        for (devices.values()) |device| {
            device.deinit(allocator);
        }
    }

    try devices.ensureTotalCapacity(allocator, bsd_names.len);

    for (bsd_names) |bsd_name| {
        if (isDiskPartition(bsd_name)) continue;

        const disk = c.DADiskCreateFromBSDName(c.kCFAllocatorDefault, session, @ptrCast(bsd_name.ptr)) orelse return error.OutOfMemory;
        defer c.CFRelease(disk);

        const description = c.DADiskCopyDescription(disk) orelse continue;
        defer c.CFRelease(description);

        devices.putAssumeCapacityNoClobber(bsd_name, try convertDescriptor(allocator, bsd_name, description));
    }

    var mount_points: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(drivelist.DeviceDescriptor.MountPoint)) = .{};
    defer {
        for (mount_points.values()) |*mps| {
            for (mps.items) |mp| {
                mp.deinit(allocator);
            }

            mps.deinit(allocator);
        }

        mount_points.deinit(allocator);
    }

    try mount_points.ensureTotalCapacity(allocator, bsd_names.len);

    // add mount points
    const volume_keys = NSArray.arrayWithObjects(&.{ NSURLVolumeNameKey.object, NSURLVolumeLocalizedNameKey.object });
    defer volume_keys.release();

    const volume_paths = NSFileManager.defaultManager().mountedVolumeURLsIncludingResourceValuesForKeys(volume_keys);
    defer volume_paths.release();

    for (0..volume_paths.count()) |i| {
        const path = volume_paths.objectAt(NSURL, @intCast(i));

        const disk = c.DADiskCreateFromVolumePath(c.kCFAllocatorDefault, session, @ptrCast(path.object.value)) orelse continue;
        defer c.CFRelease(disk);

        const bsd_name = std.mem.span(c.DADiskGetBSDName(disk) orelse continue);
        if (devices.getKey(bsd_name[0 .. std.mem.indexOfScalarPos(u8, bsd_name, 5, 's') orelse unreachable])) |disk_name| {
            const gop = mount_points.getOrPutAssumeCapacity(disk_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }

            const duped_label = try allocator.dupe(u8, convertString(path.getResourceValue(NSURLVolumeLocalizedNameKey)) orelse continue);
            errdefer allocator.free(duped_label);

            const duped_path = try allocator.dupe(u8, std.mem.span(path.path().UTF8String()));
            errdefer allocator.free(duped_path);

            try gop.value_ptr.append(allocator, .{
                .path = duped_path,
                .label = duped_label,
            });
        }
    }

    {
        // handleApfs https://github.com/balena-io-modules/drivelist/blob/a616aa9875956ecf1a546cf1d2480ff281e54d2b/lib/index.ts#L69
        var apfs: std.ArrayListUnmanaged(struct { *drivelist.DeviceDescriptor, *std.ArrayListUnmanaged(drivelist.DeviceDescriptor.MountPoint) }) = .{};
        defer apfs.deinit(allocator);

        var other: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(drivelist.DeviceDescriptor.MountPoint)) = .{};
        defer other.deinit(allocator);

        var device_iterator = devices.iterator();
        while (device_iterator.next()) |entry| {
            if (entry.value_ptr.device_path) |device_path| {
                if (entry.value_ptr.description) |description| {
                    if (std.mem.eql(u8, description, "AppleAPFSMedia")) {
                        if (mount_points.getPtr(entry.key_ptr.*)) |ptr| {
                            try apfs.append(allocator, .{ entry.value_ptr, ptr });
                        }
                        continue;
                    }
                }

                if (!entry.value_ptr.is_virtual) {
                    if (mount_points.getPtr(entry.key_ptr.*)) |ptr| {
                        try other.putNoClobber(allocator, device_path, ptr);
                    }
                }
            }
        }

        for (apfs.items) |item| {
            const device, const device_mount_points = item;
            if (device.device_path) |device_path| {
                if (other.get(device_path)) |other_mount_points| {
                    try other_mount_points.appendSlice(allocator, device_mount_points.items);
                    device.is_virtual = true;
                }
            }
        }
    }

    var device_iterator = devices.iterator();
    while (device_iterator.next()) |entry| {
        if (mount_points.getPtr(entry.key_ptr.*)) |mount_point| {
            entry.value_ptr.mount_points = try mount_point.toOwnedSlice(allocator);
        }
    }

    return try allocator.dupe(drivelist.DeviceDescriptor, devices.values());
}
