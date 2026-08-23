const std = @import("std");

const types = @import("types.zig");
const mbr_mod = @import("layout/mbr.zig");

/// Canonical layout enum. All other copies were merged into this one.
pub const Layout = types.Info.Layout;

pub const driver = @import("layout/driver.zig");
pub const mbr = mbr_mod;

comptime {
    _ = &driver;
    _ = &mbr;
}
