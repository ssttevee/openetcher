const std = @import("std");
const builtin = @import("builtin");

pub const DeviceDescriptor = struct {
    pub const PartitionTableType = enum {
        none,
        mbr,
        gpt,
    };

    pub const Enumerator = enum {
        none,
        /// macos DeviceArbitration
        device_arbitration,
    };

    pub const MountPoint = struct {
        path: []const u8,
        label: []const u8,

        pub fn deinit(self: MountPoint, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.label);
        }
    };

    enumerator: Enumerator,
    bus_type: ?[]const u8 = null,
    bus_version: ?[]const u8 = null,
    device: []const u8,
    device_path: ?[]const u8 = null,
    raw: []const u8,
    description: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    partition_table_type: PartitionTableType = .none,
    size: u64,
    block_size: u32 = 512,
    logical_block_size: u32 = 512,
    mount_points: []const MountPoint = &.{},
    /// Device is read-only
    is_read_only: bool = false,
    /// Device is a system drive
    is_system: bool = false,
    /// Device is a virtual storage device
    is_virtual: bool = false,
    /// Device is removable from the running system
    is_removable: bool = false,
    /// Device is an SD-card
    is_card: bool = false,
    /// Connected via the Small Computer System Interface (SCSI)
    is_scsi: bool = false,
    /// Connected via Universal Serial Bus (USB)
    is_usb: bool = false,
    /// Connected via the USB Attached SCSI (UAS)
    is_uas: ?bool = null,

    pub fn deinit(self: DeviceDescriptor, allocator: std.mem.Allocator) void {
        for (self.mount_points) |mountpoint| {
            mountpoint.deinit(allocator);
        }

        allocator.free(self.mount_points);

        if (self.bus_version) |bus_version| {
            allocator.free(bus_version);
        }

        if (self.bus_type) |bus_type| {
            allocator.free(bus_type);
        }

        if (self.device_path) |device_path| {
            allocator.free(device_path);
        }

        if (self.description) |description| {
            allocator.free(description);
        }

        if (self.error_message) |error_message| {
            allocator.free(error_message);
        }

        allocator.free(self.raw);
        allocator.free(self.device);
    }
};
