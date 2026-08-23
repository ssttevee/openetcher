const std = @import("std");
const range = @import("../range.zig");

pub const ByteRange = range.ByteRange;

pub const Filesystem = enum {
    ext4,
    fat16,
    fat32,
    iso9660,
    squashfs,
    empty,
    linux_unknown,
    unknown,
};

/// Driver contract and format registry. See driver.zig.
pub const driver = @import("fs/driver.zig");
pub const Driver = driver.Driver;

pub const ext4 = @import("fs/ext4.zig");
pub const fat = @import("fs/fat.zig");
pub const iso9660 = @import("fs/iso9660.zig");
pub const squashfs = @import("fs/squashfs.zig");

comptime {
    _ = driver;
}
