pub const Filesystem = enum {
    ext4,
    fat16,
    fat32,
    squashfs,
    empty,
    linux_unknown,
    unknown,
};

pub const ext4 = @import("fs/ext4.zig");
pub const fat = @import("fs/fat.zig");
pub const squashfs = @import("fs/squashfs.zig");
