pub const DeviceDescriptor = @import("drivelist.zig").DeviceDescriptor;

pub const Cursor = enum {
    arrow,
    pointer,

    pub const default = Cursor.arrow;
};
