const std = @import("std");
const objc = @import("objc.zig");
const common = @import("common.zig");

const NSString = common.NSString;
const NSArray = common.NSArray;
const NSURL = common.NSURL;

const NSOpenPanel = objc.ExternalClass(
    "NSOpenPanel",
    struct {
        pub fn openPanel() NSOpenPanel {
            return NSOpenPanel.class().msgSend(NSOpenPanel, "openPanel", .{});
        }

        pub fn setAllowsMultipleSelection(self: NSOpenPanel, b: bool) void {
            self.msgSend(void, "setAllowsMultipleSelection:", .{b});
        }

        pub fn setResolvesAliases(self: NSOpenPanel, b: bool) void {
            self.msgSend(void, "setResolvesAliases:", .{b});
        }

        pub fn setMessage(self: NSOpenPanel, s: NSString) void {
            self.msgSend(void, "setMessage:", .{s});
        }

        pub fn runModal(self: NSOpenPanel) bool {
            return self.msgSend(bool, "runModal", .{});
        }

        pub fn URLs(self: NSOpenPanel) NSArray {
            return self.msgSend(NSArray, "URLs", .{});
        }
    },
);

pub fn selectImageFile(allocator: std.mem.Allocator) !?[]const u8 {
    const panel = NSOpenPanel.openPanel();

    panel.setAllowsMultipleSelection(false);
    panel.setResolvesAliases(true);
    panel.setMessage(NSString.stringWithUTF8String("Select an image"));

    if (panel.runModal()) {
        var urls_iterator = panel.URLs().iterator();
        while (urls_iterator.next(NSURL)) |url| {
            return try allocator.dupe(u8, std.mem.span(url.path().UTF8String()));
        }
    }

    return null;
}
