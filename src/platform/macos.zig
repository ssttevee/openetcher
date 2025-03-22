const appkit = @import("macos/appkit.zig");

pub fn setCursor(cursor: @import("common.zig").Cursor) void {
    (switch (cursor) {
        .arrow => appkit.NSCursor.arrowCursor(),
        .pointer => appkit.NSCursor.pointingHandCursor(),
    }).set();
}

pub const App = @import("macos/frontend.zig").App;
pub const listStorageDevices = @import("macos/drivelist.zig").listStorageDevices;
pub const selectImageFile = @import("macos/fileselector.zig").selectImageFile;
