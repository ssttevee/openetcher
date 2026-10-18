//! The Win32 declarations the Windows backend uses: SetupAPI to enumerate
//! disks, `DeviceIoControl` to query them, and the shell's known folders to
//! find the system disk. Zig links these DLLs' import libraries itself.

const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const GUID = windows.GUID;
pub const BOOL = c_int;
pub const HDEVINFO = *opaque {};

pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const INVALID_HDEVINFO: HDEVINFO = @ptrFromInt(std.math.maxInt(usize));
pub const CloseHandle = windows.CloseHandle;
pub const GetLastError = windows.GetLastError;

pub const GUID_DEVINTERFACE_DISK: GUID = .parse("{53F56307-B6BF-11D0-94F2-00A0C91EFB8B}");
pub const FOLDERID_Windows: GUID = .parse("{F38BF404-1D43-42F2-9305-67DE0B28FC23}");
pub const FOLDERID_Profile: GUID = .parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
pub const FOLDERID_ProgramFiles: GUID = .parse("{905E63B6-C1BF-494E-B29C-65B732D3D21A}");
pub const FOLDERID_ProgramFilesX86: GUID = .parse("{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}");

pub const DIGCF_PRESENT: u32 = 0x02;
pub const DIGCF_DEVICEINTERFACE: u32 = 0x10;

pub const SPDRP_HARDWAREID: u32 = 0x01;
pub const SPDRP_FRIENDLYNAME: u32 = 0x0C;
pub const SPDRP_ENUMERATOR_NAME: u32 = 0x16;
pub const SPDRP_REMOVAL_POLICY: u32 = 0x1F;

pub const CM_REMOVAL_POLICY_EXPECT_ORDERLY_REMOVAL: u32 = 2;
pub const CM_REMOVAL_POLICY_EXPECT_SURPRISE_REMOVAL: u32 = 3;

pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const OPEN_EXISTING: u32 = 3;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

pub const DRIVE_REMOVABLE: u32 = 2;
pub const DRIVE_FIXED: u32 = 3;

pub const SP_DEVINFO_DATA = extern struct {
    cbSize: u32 = @sizeOf(SP_DEVINFO_DATA),
    ClassGuid: GUID = std.mem.zeroes(GUID),
    DevInst: u32 = 0,
    Reserved: usize = 0,
};

pub const SP_DEVICE_INTERFACE_DATA = extern struct {
    cbSize: u32 = @sizeOf(SP_DEVICE_INTERFACE_DATA),
    InterfaceClassGuid: GUID = std.mem.zeroes(GUID),
    Flags: u32 = 0,
    Reserved: usize = 0,
};

/// `cbSize` of `SP_DEVICE_INTERFACE_DETAIL_DATA_W`, a `DWORD` followed by a
/// path of `WCHAR`s: 8 bytes with 64-bit alignment, 6 when packed for 32-bit.
pub const device_interface_detail_size: u32 = if (@sizeOf(usize) == 8) 8 else 6;

fn ctlCode(device_type: u32, function: u32) u32 {
    // METHOD_BUFFERED and FILE_ANY_ACCESS, which every code here uses.
    return (device_type << 16) | (function << 2);
}

const FILE_DEVICE_DISK: u32 = 0x07;
const IOCTL_STORAGE_BASE: u32 = 0x2D;
const IOCTL_VOLUME_BASE: u32 = 0x56;

pub const IOCTL_DISK_IS_WRITABLE = ctlCode(FILE_DEVICE_DISK, 0x09);
pub const IOCTL_DISK_GET_DRIVE_LAYOUT_EX = ctlCode(FILE_DEVICE_DISK, 0x14);
pub const IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = ctlCode(FILE_DEVICE_DISK, 0x28);
pub const IOCTL_STORAGE_GET_DEVICE_NUMBER = ctlCode(IOCTL_STORAGE_BASE, 0x420);
pub const IOCTL_STORAGE_QUERY_PROPERTY = ctlCode(IOCTL_STORAGE_BASE, 0x500);
pub const IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = ctlCode(IOCTL_VOLUME_BASE, 0x00);

pub const StorageAdapterProperty: u32 = 1;
pub const StorageAccessAlignmentProperty: u32 = 6;
pub const PropertyStandardQuery: u32 = 0;

pub const STORAGE_PROPERTY_QUERY = extern struct {
    PropertyId: u32,
    QueryType: u32 = PropertyStandardQuery,
    AdditionalParameters: [1]u8 = .{0},
};

pub const STORAGE_BUS_TYPE = enum(u8) {
    unknown,
    scsi,
    atapi,
    ata,
    ieee1394,
    ssa,
    fibre,
    usb,
    raid,
    iscsi,
    sas,
    sata,
    sd,
    mmc,
    virtual,
    file_backed_virtual,
    spaces,
    nvme,
    scm,
    ufs,
    _,
};

pub const STORAGE_ADAPTER_DESCRIPTOR = extern struct {
    Version: u32,
    Size: u32,
    MaximumTransferLength: u32,
    MaximumPhysicalPages: u32,
    AlignmentMask: u32,
    AdapterUsesPio: u8,
    AdapterScansDown: u8,
    CommandQueueing: u8,
    AcceleratedTransfer: u8,
    BusType: STORAGE_BUS_TYPE,
    BusMajorVersion: u16,
    BusMinorVersion: u16,
    SrbType: u8,
    AddressType: u8,
};

pub const STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR = extern struct {
    Version: u32,
    Size: u32,
    BytesPerCacheLine: u32,
    BytesOffsetForCacheAlignment: u32,
    BytesPerLogicalSector: u32,
    BytesPerPhysicalSector: u32,
    BytesOffsetForSectorAlignment: u32,
};

pub const STORAGE_DEVICE_NUMBER = extern struct {
    DeviceType: u32,
    DeviceNumber: u32,
    PartitionNumber: u32,
};

pub const DISK_EXTENT = extern struct {
    DiskNumber: u32,
    StartingOffset: i64,
    ExtentLength: i64,
};

pub const VOLUME_DISK_EXTENTS = extern struct {
    NumberOfDiskExtents: u32,
    Extents: [1]DISK_EXTENT,
};

pub const DISK_GEOMETRY = extern struct {
    Cylinders: i64,
    MediaType: u32,
    TracksPerCylinder: u32,
    SectorsPerTrack: u32,
    BytesPerSector: u32,
};

pub const DISK_GEOMETRY_EX = extern struct {
    Geometry: DISK_GEOMETRY,
    DiskSize: i64,
    Data: [1]u8,
};

pub const PARTITION_STYLE_MBR: u32 = 0;
pub const PARTITION_STYLE_GPT: u32 = 1;

/// The fixed head of `DRIVE_LAYOUT_INFORMATION_EX`; its union and partition
/// entries follow.
pub const DRIVE_LAYOUT_INFORMATION_EX_HEAD = extern struct {
    PartitionStyle: u32,
    PartitionCount: u32,
};

/// `sizeof(DRIVE_LAYOUT_INFORMATION_EX)` and `sizeof(PARTITION_INFORMATION_EX)`.
pub const drive_layout_size = 48;
pub const partition_information_size = 144;

pub extern "setupapi" fn SetupDiGetClassDevsW(class_guid: ?*const GUID, enumerator: ?[*:0]const u16, parent: ?*anyopaque, flags: u32) callconv(.winapi) HDEVINFO;
pub extern "setupapi" fn SetupDiDestroyDeviceInfoList(info: HDEVINFO) callconv(.winapi) BOOL;
pub extern "setupapi" fn SetupDiEnumDeviceInfo(info: HDEVINFO, index: u32, data: *SP_DEVINFO_DATA) callconv(.winapi) BOOL;
pub extern "setupapi" fn SetupDiGetDeviceRegistryPropertyW(info: HDEVINFO, data: *SP_DEVINFO_DATA, property: u32, reg_type: ?*u32, buffer: ?[*]u8, size: u32, required: ?*u32) callconv(.winapi) BOOL;
pub extern "setupapi" fn SetupDiEnumDeviceInterfaces(info: HDEVINFO, data: ?*SP_DEVINFO_DATA, guid: *const GUID, index: u32, interface: *SP_DEVICE_INTERFACE_DATA) callconv(.winapi) BOOL;
pub extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(info: HDEVINFO, interface: *SP_DEVICE_INTERFACE_DATA, detail: ?*anyopaque, size: u32, required: ?*u32, data: ?*SP_DEVINFO_DATA) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn DeviceIoControl(device: HANDLE, code: u32, in: ?*const anyopaque, in_size: u32, out: ?*anyopaque, out_size: u32, returned: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
pub extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;

pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: u32, token: ?HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
pub extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

test "structure layouts match the Windows SDK" {
    try std.testing.expectEqual(32, @sizeOf(STORAGE_ADAPTER_DESCRIPTOR));
    try std.testing.expectEqual(24, @sizeOf(DISK_EXTENT));
    try std.testing.expectEqual(32, @sizeOf(VOLUME_DISK_EXTENTS));
    try std.testing.expectEqual(40, @sizeOf(DISK_GEOMETRY_EX));
    try std.testing.expectEqual(12, @sizeOf(STORAGE_PROPERTY_QUERY));
    try std.testing.expectEqual(0x2D1400, IOCTL_STORAGE_QUERY_PROPERTY);
    try std.testing.expectEqual(0x2D1080, IOCTL_STORAGE_GET_DEVICE_NUMBER);
    try std.testing.expectEqual(0x560000, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS);
    try std.testing.expectEqual(0x700A0, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX);
    try std.testing.expectEqual(0x70050, IOCTL_DISK_GET_DRIVE_LAYOUT_EX);
    try std.testing.expectEqual(0x70024, IOCTL_DISK_IS_WRITABLE);
}
