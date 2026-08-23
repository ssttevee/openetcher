const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

/// Contract every filesystem planner satisfies.
///
/// Add a filesystem: create one module exposing `pub const driver`, then list
/// it in `drivers`. No other file changes.
pub const Driver = struct {
    /// MBR partition-type bytes routed to this driver before content sniffing.
    mbr_types: []const u8 = &.{},
    /// Cheap content sniff in reader coordinates. Must not allocate.
    /// Offset 0 of the reader is the start of the candidate region.
    detect: *const fn (io: std.Io, r: *const reader_mod.Reader) bool,
    /// Probes the region as this filesystem. The returned `PartitionInfo` uses
    /// reader-relative offsets; the caller fills `index`, `start_offset`,
    /// `size`, and `partition_type`.
    probe_region: *const fn (allocator: std.mem.Allocator, io: std.Io, r: *const reader_mod.Reader) anyerror!types.Info.PartitionInfo,
    /// Collects write ranges relative to the region start.
    collect_ranges: *const fn (allocator: std.mem.Allocator, io: std.Io, r: *const reader_mod.Reader) anyerror![]range.ByteRange,
    /// Set when the driver can flash a whole unpartitioned image by itself.
    raw_layout: ?types.Info.Layout = null,
    /// Filesystem tag reported for a raw whole-image layout.
    filesystem_tag: ?types.Info.Filesystem = null,
    /// Block size for a raw whole-image layout.
    block_size_fn: ?*const fn (io: std.Io, r: *const reader_mod.Reader) anyerror!u32 = null,
};

/// Registry order is content-sniffing precedence.
pub const drivers = [_]Driver{
    @import("iso9660.zig").driver,
    @import("fat.zig").driver,
    @import("squashfs.zig").driver,
    @import("ext4.zig").driver,
};

const iso9660_driver = &@import("iso9660.zig").driver;
const fat_driver = &@import("fat.zig").driver;
const squashfs_driver = &@import("squashfs.zig").driver;
const ext4_driver = &@import("ext4.zig").driver;

pub const slice = [_]*const Driver{ iso9660_driver, fat_driver, squashfs_driver, ext4_driver };

pub fn findByMbrType(partition_type: u8) ?*const Driver {
    for (slice) |driver| {
        for (driver.mbr_types) |candidate| {
            if (candidate == partition_type) return driver;
        }
    }
    return null;
}

pub fn findByContent(io: std.Io, r: *const reader_mod.Reader) ?*const Driver {
    for (slice) |driver| {
        if (driver.detect(io, r)) return driver;
    }
    return null;
}

test "findByMbrType routes FAT partition types" {
    try std.testing.expectEqual(fat_driver_ptr(), findByMbrType(0x06).?);
    try std.testing.expectEqual(fat_driver_ptr(), findByMbrType(0x0c).?);
    try std.testing.expect(findByMbrType(0x83) == null);
    try std.testing.expect(findByMbrType(0x00) == null);
}

fn fat_driver_ptr() *const Driver {
    for (slice) |driver| {
        if (driver.mbr_types.len != 0) return driver;
    }
    unreachable;
}
