//! Windows backend. Disks are discovered the way Etcher's drivelist does:
//! SetupAPI enumerates the disk interfaces, and `DeviceIoControl` queries
//! each physical drive and volume. Raw-device writes are not supported yet,
//! so only regular-file targets open.

const std = @import("std");

const regular_file = @import("regular_file.zig");
const device = @import("../../device.zig");
const discovery = @import("../discovery.zig");
const target_io_api = @import("target_io.zig");
const win32 = @import("windows/win32.zig");

pub const probeTarget = regular_file.probeTarget;
pub const openTarget = regular_file.openTarget;
pub const prepareTargetPath = regular_file.prepareTargetPath;
pub const prepareTarget = regular_file.prepareTarget;

pub const target_io = target_io_api.positional_only;

/// Storage drivers whose disks hang off USB.
const usb_storage_drivers: std.StaticStringMap(void) = .initComptime(.{
    .{"USBSTOR"}, .{"UASPSTOR"}, .{"VUSBSTOR"}, .{"RTUSER"}, .{"CMIUCR"}, .{"EUCR"}, .{"ETRONSTOR"}, .{"ASUSSTPT"},
});

/// Storage drivers for SCSI, SATA, and built-in card readers.
const generic_storage_drivers: std.StaticStringMap(void) = .initComptime(.{
    .{"SCSI"},     .{"SD"},       .{"PCISTOR"}, .{"RTSOR"},  .{"JMCR"}, .{"JMCF"}, .{"RIMMPTSK"}, .{"RIMSPTSK"},
    .{"RIXDPTSK"}, .{"TI21SONY"}, .{"ESD7SK"},  .{"ESM7SK"}, .{"O2MD"}, .{"O2SD"}, .{"VIACR"},
});

/// Hardware ids of virtual disk drivers.
const virtual_hardware_ids = [_][]const u8{ "Arsenal_________Virtual_", "KernSafeVirtual_________", "Msft____Virtual_Disk____", "VMware__VMware_Virtual_S" };

pub fn enumerateDisks(arena: std.mem.Allocator, _: std.Io) discovery.ListError![]device.CandidateDisk {
    const info = win32.SetupDiGetClassDevsW(&win32.GUID_DEVINTERFACE_DISK, null, null, win32.DIGCF_PRESENT | win32.DIGCF_DEVICEINTERFACE);
    if (info == win32.INVALID_HDEVINFO) return error.DiskListFailed;
    defer _ = win32.SetupDiDestroyDeviceInfoList(info);

    const volumes = try volumeDisks(arena);
    const system_folders = try systemFolders(arena);

    var disks: std.ArrayList(device.CandidateDisk) = .empty;
    var index: u32 = 0;
    while (true) : (index += 1) {
        var data: win32.SP_DEVINFO_DATA = .{};
        if (win32.SetupDiEnumDeviceInfo(info, index, &data) == 0) break;
        const disk = try describe(arena, info, &data, volumes, system_folders) orelse continue;
        try disks.append(arena, disk);
    }
    return disks.items;
}

pub fn wholeDiskPath(_: std.mem.Allocator, _: std.Io, path: []const u8) []const u8 {
    return path;
}

/// Drivelist's `ListStorageDevices` loop body for one device; null where
/// drivelist would report an error, since Etcher leaves those drives out.
fn describe(
    arena: std.mem.Allocator,
    info: win32.HDEVINFO,
    data: *win32.SP_DEVINFO_DATA,
    volumes: []const Volume,
    system_folders: []const []const u8,
) std.mem.Allocator.Error!?device.CandidateDisk {
    const enumerator = try registryString(arena, info, data, win32.SPDRP_ENUMERATOR_NAME) orelse return null;
    if (enumerator.len == 0) return null;
    const friendly_name = try registryString(arena, info, data, win32.SPDRP_FRIENDLYNAME) orelse "";
    const hardware_id = try registryString(arena, info, data, win32.SPDRP_HARDWAREID) orelse "";
    const removable = switch (registryNumber(info, data, win32.SPDRP_REMOVAL_POLICY) orelse 0) {
        win32.CM_REMOVAL_POLICY_EXPECT_ORDERLY_REMOVAL, win32.CM_REMOVAL_POLICY_EXPECT_SURPRISE_REMOVAL => true,
        else => false,
    };
    const virtual_hardware = for (virtual_hardware_ids) |id| {
        if (std.mem.indexOf(u8, hardware_id, id) != null) break true;
    } else false;

    const interface_path = try interfacePath(arena, info, data) orelse return null;
    const details = try queryDisk(arena, interface_path) orelse return null;

    var mount_points: std.ArrayList(device.MountPoint) = .empty;
    for (volumes) |volume| {
        if (volume.disk_number == details.number) try mount_points.append(arena, .{ .path = volume.root });
    }
    const system = (!removable and (std.mem.eql(u8, enumerator, "SCSI") or std.mem.eql(u8, enumerator, "IDE"))) or
        holdsSystemFolder(mount_points.items, system_folders);
    const raw_path = try std.fmt.allocPrint(arena, "\\\\.\\PhysicalDrive{d}", .{details.number});
    return .{
        .id = try discovery.diskId(arena, "windows", &.{ busTypeName(details.bus_type), friendly_name, interface_path }, details.size),
        .device_path = raw_path,
        .raw_path = raw_path,
        .display_name = try discovery.displayName(arena, raw_path, mount_points.items),
        .description = friendly_name,
        .bus_type = busTypeName(details.bus_type),
        .location = interface_path,
        .size = details.size,
        .block_size = details.block_size,
        .logical_block_size = details.logical_block_size,
        .partition_table = details.partition_table,
        .protected = discovery.isProtected(system, mount_points.items),
        .system = system,
        .removable = removable,
        .read_only = details.read_only,
        .virtual = virtual_hardware or details.bus_type == .virtual or details.bus_type == .file_backed_virtual,
        .card = details.bus_type == .sd or details.bus_type == .mmc,
        .usb = usb_storage_drivers.has(enumerator),
        .scsi = generic_storage_drivers.has(enumerator),
        .raid = details.bus_type == .raid,
        .mount_points = mount_points.items,
    };
}

fn holdsSystemFolder(mount_points: []const device.MountPoint, system_folders: []const []const u8) bool {
    for (system_folders) |folder| {
        for (mount_points) |mount_point| {
            if (std.ascii.startsWithIgnoreCase(folder, mount_point.path)) return true;
        }
    }
    return false;
}

/// A string device property as UTF-8; for multi-string properties such as
/// hardware ids, the first string.
fn registryString(arena: std.mem.Allocator, info: win32.HDEVINFO, data: *win32.SP_DEVINFO_DATA, property: u32) std.mem.Allocator.Error!?[]const u8 {
    var buffer: [1024]u16 align(@alignOf(u32)) = @splat(0);
    if (win32.SetupDiGetDeviceRegistryPropertyW(info, data, property, null, @ptrCast(&buffer), @sizeOf(@TypeOf(buffer)) - 2, null) == 0) return null;
    return try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(&buffer, 0));
}

fn registryNumber(info: win32.HDEVINFO, data: *win32.SP_DEVINFO_DATA, property: u32) ?u32 {
    var value: u32 = 0;
    if (win32.SetupDiGetDeviceRegistryPropertyW(info, data, property, null, @ptrCast(&value), @sizeOf(u32), null) == 0) return null;
    return value;
}

/// The path of the device's disk interface, which `CreateFileW` opens.
fn interfacePath(arena: std.mem.Allocator, info: win32.HDEVINFO, data: *win32.SP_DEVINFO_DATA) std.mem.Allocator.Error!?[]const u8 {
    var interface: win32.SP_DEVICE_INTERFACE_DATA = .{};
    if (win32.SetupDiEnumDeviceInterfaces(info, data, &win32.GUID_DEVINTERFACE_DISK, 0, &interface) == 0) return null;
    var size: u32 = 0;
    _ = win32.SetupDiGetDeviceInterfaceDetailW(info, &interface, null, 0, &size, null);
    if (size <= @sizeOf(u32)) return null;
    const detail = try arena.alignedAlloc(u8, .of(u32), size);
    std.mem.writeInt(u32, detail[0..4], win32.device_interface_detail_size, .little);
    if (win32.SetupDiGetDeviceInterfaceDetailW(info, &interface, detail.ptr, size, null, null) == 0) return null;
    const path_bytes = detail[@sizeOf(u32)..];
    const path: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, path_bytes[0 .. path_bytes.len & ~@as(usize, 1)]));
    return try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(path, 0));
}

const DiskDetails = struct {
    number: u32,
    size: u64,
    block_size: u32,
    logical_block_size: u32,
    partition_table: ?device.PartitionTable,
    bus_type: win32.STORAGE_BUS_TYPE,
    read_only: bool,
};

/// Drivelist's `GetDetailData`: the drive's number from its interface, then
/// its geometry, layout, and adapter from the physical drive. Opening with
/// no access rights reads metadata without needing administrator rights.
fn queryDisk(arena: std.mem.Allocator, interface_path: []const u8) std.mem.Allocator.Error!?DiskDetails {
    const interface = try openForQuery(arena, interface_path) orelse return null;
    defer win32.CloseHandle(interface);
    const number = deviceNumber(interface) orelse return null;

    const physical = try openForQuery(arena, try std.fmt.allocPrint(arena, "\\\\.\\PhysicalDrive{d}", .{number})) orelse return null;
    defer win32.CloseHandle(physical);

    // `Data` begins the variable-length detection information, which
    // drivers need not return.
    const geometry = query(win32.DISK_GEOMETRY_EX, bytesThrough(win32.DISK_GEOMETRY_EX, "DiskSize"), physical, win32.IOCTL_DISK_GET_DRIVE_GEOMETRY_EX) orelse return null;
    // Older Windows versions return a shorter descriptor, ending before
    // `SrbType`.
    const adapter = queryProperty(win32.STORAGE_ADAPTER_DESCRIPTOR, bytesThrough(win32.STORAGE_ADAPTER_DESCRIPTOR, "BusType"), physical, win32.StorageAdapterProperty) orelse return null;
    // Not every bridge answers this; the geometry's sector size stands.
    const alignment = queryProperty(win32.STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR, bytesThrough(win32.STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR, "BytesPerPhysicalSector"), physical, win32.StorageAccessAlignmentProperty);

    // Windows reports anything without a GPT as MBR; only a real MBR
    // carries a multiple of four entries.
    const layout = try arena.alignedAlloc(u8, .of(u64), win32.drive_layout_size + 256 * win32.partition_information_size);
    @memset(layout, 0);
    const layout_bytes = queryInto(physical, win32.IOCTL_DISK_GET_DRIVE_LAYOUT_EX, layout) orelse return null;
    if (layout_bytes < @sizeOf(win32.DRIVE_LAYOUT_INFORMATION_EX_HEAD)) return null;
    const head = std.mem.bytesAsValue(win32.DRIVE_LAYOUT_INFORMATION_EX_HEAD, layout[0..@sizeOf(win32.DRIVE_LAYOUT_INFORMATION_EX_HEAD)]);

    return .{
        .number = number,
        .size = std.math.cast(u64, geometry.DiskSize) orelse 0,
        .block_size = if (alignment) |a| a.BytesPerPhysicalSector else geometry.Geometry.BytesPerSector,
        .logical_block_size = if (alignment) |a| a.BytesPerLogicalSector else geometry.Geometry.BytesPerSector,
        .partition_table = switch (head.PartitionStyle) {
            win32.PARTITION_STYLE_GPT => .gpt,
            win32.PARTITION_STYLE_MBR => if (head.PartitionCount % 4 == 0) .mbr else null,
            else => null,
        },
        .bus_type = adapter.BusType,
        .read_only = !succeeds(physical, win32.IOCTL_DISK_IS_WRITABLE),
    };
}

fn openForQuery(arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?win32.HANDLE {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return null,
    };
    const handle = win32.CreateFileW(wide, 0, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    return if (handle == win32.INVALID_HANDLE_VALUE) null else handle;
}

/// The bytes of `Out` up to the end of `field`: how much of a reply must
/// arrive for `field` to have been written. Some replies end early, either
/// at a variable-length tail or because an older Windows defines less.
fn bytesThrough(comptime Out: type, comptime field: []const u8) u32 {
    return @offsetOf(Out, field) + @sizeOf(@FieldType(Out, field));
}

/// The answer to `code` as an `Out`; null when the device refuses it or
/// writes fewer than `min_bytes`. Bytes it does not write stay zero.
fn query(comptime Out: type, comptime min_bytes: u32, handle: win32.HANDLE, code: u32) ?Out {
    var out: Out = std.mem.zeroes(Out);
    const returned = queryInto(handle, code, std.mem.asBytes(&out)) orelse return null;
    return if (returned >= min_bytes) out else null;
}

/// A storage property, through `IOCTL_STORAGE_QUERY_PROPERTY`, checked as
/// `query` checks its answer.
fn queryProperty(comptime Out: type, comptime min_bytes: u32, handle: win32.HANDLE, property: u32) ?Out {
    const request: win32.STORAGE_PROPERTY_QUERY = .{ .PropertyId = property };
    var out: Out = std.mem.zeroes(Out);
    var returned: u32 = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_STORAGE_QUERY_PROPERTY, &request, @sizeOf(win32.STORAGE_PROPERTY_QUERY), &out, @sizeOf(Out), &returned, null) == 0) return null;
    return if (returned >= min_bytes) out else null;
}

/// Issues `code` and reads the answer into `output`, returning how many
/// bytes the device wrote; null when it refuses.
fn queryInto(handle: win32.HANDLE, code: u32, output: []u8) ?u32 {
    var returned: u32 = 0;
    if (win32.DeviceIoControl(handle, code, null, 0, output.ptr, @intCast(output.len), &returned, null) == 0) return null;
    return returned;
}

/// Whether the device answers `code`, which carries no data either way.
fn succeeds(handle: win32.HANDLE, code: u32) bool {
    return queryInto(handle, code, &.{}) != null;
}

/// The number of the physical drive behind a disk interface or volume.
/// Volumes that span several drives, such as RAID sets, have none, like
/// drivelist, which leaves RAIDs out.
fn deviceNumber(handle: win32.HANDLE) ?u32 {
    var extents = std.mem.zeroes(win32.VOLUME_DISK_EXTENTS);
    const extents_bytes = queryInto(handle, win32.IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, std.mem.asBytes(&extents));
    // The buffer holds one extent, so a volume with more fails to fit.
    if (extents_bytes == null and win32.GetLastError() == .MORE_DATA) return null;
    // Most devices answer only this; where both answer, it wins.
    if (query(win32.STORAGE_DEVICE_NUMBER, @sizeOf(win32.STORAGE_DEVICE_NUMBER), handle, win32.IOCTL_STORAGE_GET_DEVICE_NUMBER)) |storage| return storage.DeviceNumber;
    if ((extents_bytes orelse return null) < bytesThrough(win32.VOLUME_DISK_EXTENTS, "Extents")) return null;
    return if (extents.NumberOfDiskExtents == 1) extents.Extents[0].DiskNumber else null;
}

const Volume = struct {
    /// The drive root, such as `E:\`.
    root: []const u8,
    disk_number: u32,
};

/// The fixed and removable drive letters with the physical drive each is
/// on. Drivelist skips optical and network drives because their device
/// numbers come from other drivers and can collide with disks'.
fn volumeDisks(arena: std.mem.Allocator) std.mem.Allocator.Error![]const Volume {
    var volumes: std.ArrayList(Volume) = .empty;
    const mask = win32.GetLogicalDrives();
    for (0..26) |bit| {
        if (mask & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        const letter: u8 = 'A' + @as(u8, @intCast(bit));
        const root_wide = [_:0]u16{ letter, ':', '\\' };
        const drive_type = win32.GetDriveTypeW(&root_wide);
        if (drive_type != win32.DRIVE_FIXED and drive_type != win32.DRIVE_REMOVABLE) continue;
        const handle = try openForQuery(arena, &.{ '\\', '\\', '.', '\\', letter, ':' }) orelse continue;
        defer win32.CloseHandle(handle);
        const number = deviceNumber(handle) orelse continue;
        try volumes.append(arena, .{ .root = try arena.dupe(u8, &.{ letter, ':', '\\' }), .disk_number = number });
    }
    return volumes.items;
}

/// The Windows, profile, and program folders, whose drive is the system's.
fn systemFolders(arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
    var folders: std.ArrayList([]const u8) = .empty;
    const ids = [_]*const win32.GUID{ &win32.FOLDERID_Windows, &win32.FOLDERID_Profile, &win32.FOLDERID_ProgramFiles, &win32.FOLDERID_ProgramFilesX86 };
    for (ids) |id| {
        var path: ?[*:0]u16 = null;
        const result = win32.SHGetKnownFolderPath(id, 0, null, &path);
        defer win32.CoTaskMemFree(path);
        if (result != 0) continue;
        try folders.append(arena, try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(path orelse continue)));
    }
    return folders.items;
}

/// Bus type names as drivelist spells them, plus the bus types Windows
/// added since.
fn busTypeName(bus_type: win32.STORAGE_BUS_TYPE) []const u8 {
    return switch (bus_type) {
        .unknown => "UNKNOWN",
        .scsi => "SCSI",
        .atapi => "ATAPI",
        .ata => "ATA",
        .ieee1394 => "1394",
        .ssa => "SSA",
        .fibre => "FIBRE",
        .usb => "USB",
        .raid => "RAID",
        .iscsi => "iSCSI",
        .sas => "SAS",
        .sata => "SATA",
        .sd => "SD",
        .mmc => "MMC",
        .virtual => "VIRTUAL",
        .file_backed_virtual => "FILEBACKEDVIRTUAL",
        .spaces => "SPACES",
        .nvme => "NVME",
        .scm => "SCM",
        .ufs => "UFS",
        _ => "INVALID",
    };
}

test "busTypeName follows STORAGE_BUS_TYPE" {
    try std.testing.expectEqualStrings("USB", busTypeName(@fromBackingInt(@intCast(7))));
    try std.testing.expectEqualStrings("RAID", busTypeName(@fromBackingInt(@intCast(8))));
    try std.testing.expectEqualStrings("FILEBACKEDVIRTUAL", busTypeName(@fromBackingInt(@intCast(15))));
    try std.testing.expectEqualStrings("NVME", busTypeName(@fromBackingInt(@intCast(17))));
    try std.testing.expectEqualStrings("INVALID", busTypeName(@fromBackingInt(@intCast(0x7F))));
}

test "enumerateDisks runs" {
    // Under Wine there are no disk interfaces; on Windows there are. Either
    // way the enumeration must complete without leaking or crashing.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const disks = enumerateDisks(arena.allocator(), std.testing.io) catch |err| switch (err) {
        error.DiskListFailed => return,
        else => return err,
    };
    for (disks) |disk| try std.testing.expect(std.mem.startsWith(u8, disk.device_path, "\\\\.\\PhysicalDrive"));
}
