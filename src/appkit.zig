const std = @import("std");
const objc = @import("objc");
pub const cg = @import("core_graphics.zig");

const ExternalClass = @import("objc.zig").ExternalClass;

pub const NSObject = ExternalClass(
    "NSObject",
    struct {},
);

pub const NSView = ExternalClass(
    "NSView",
    struct {
        pub fn initWithFrame(self: NSView, rect: cg.Rect) void {
            self.msgSend(void, "initWithFrame:", .{rect});
        }

        pub fn bounds(self: NSView) cg.Rect {
            return self.msgSend(cg.Rect, "bounds", .{});
        }

        pub fn lockFocus(self: NSView) void {
            self.msgSend(void, "lockFocus", .{});
        }

        pub fn unlockFocus(self: NSView) void {
            self.msgSend(void, "unlockFocus", .{});
        }

        pub fn convertPoint(self: NSView, point: cg.Point, from: ?NSView) cg.Point {
            return self.msgSend(cg.Point, "convertPoint:fromView:", .{ point, if (from) |v| v.object.value else null });
        }

        pub fn addTrackingArea(self: NSView, area: NSTrackingArea) void {
            self.msgSend(void, "addTrackingArea:", .{area});
        }

        pub fn visibleRect(self: NSView) cg.Rect {
            return self.msgSend(cg.Rect, "visibleRect", .{});
        }
    },
);

pub const NSColor = ExternalClass(
    "NSColor",
    struct {
        pub fn set(self: NSColor) void {
            self.msgSend(void, "set", .{});
        }
    },
);

pub const NSApplication = ExternalClass(
    "NSApplication",
    struct {
        pub const ActivationPolicy = enum(u32) {
            regular = 0,
            accessory = 1,
            err = 2,
        };

        pub fn sharedApplication() NSApplication {
            return NSApplication.class().msgSend(NSApplication, "sharedApplication", .{});
        }

        pub fn setActivationPolicy(self: NSApplication, policy: ActivationPolicy) void {
            self.msgSend(void, "setActivationPolicy:", .{policy});
        }

        pub fn setDelegate(self: NSApplication, delegate: anytype) void {
            self.msgSend(void, "setDelegate:", .{delegate});
        }

        pub fn activateIgnoringOtherApps(self: NSApplication, activate: bool) void {
            self.msgSend(void, "activateIgnoringOtherApps:", .{activate});
        }

        pub fn run(self: NSApplication) void {
            self.msgSend(void, "run", .{});
        }
    },
);

pub const NSBackingStoreType = enum(u32) {
    buffered = 2,
};

pub extern fn NSRectFill(rect: cg.Rect) callconv(.C) void;

pub extern const NSWindowWillCloseNotification: NSNotification.Name;

pub const NSWindow = ExternalClass(
    "NSWindow",
    struct {
        pub const StyleMask = packed struct(u32) {
            titled: bool = false,
            closable: bool = false,
            miniaturizable: bool = false,
            resizable: bool = false,
            _: u28 = 0,

            pub const fullscreen: StyleMask = .{};
        };

        pub fn init(self: NSWindow, rect: cg.Rect, window_style: StyleMask, backing: NSBackingStoreType, @"defer": bool) void {
            self.msgSend(void, "initWithContentRect:styleMask:backing:defer:", .{ rect, window_style, backing, @"defer" });
        }

        pub fn setContentView(self: NSWindow, view: anytype) void {
            self.msgSend(void, "setContentView:", .{view});
        }

        pub fn becomeFirstResponder(self: NSWindow) void {
            self.msgSend(void, "becomeFirstResponder", .{});
        }

        pub fn setTitle(self: NSWindow, title: NSString) void {
            self.msgSend(void, "setTitle:", .{title});
        }

        pub fn makeKeyAndOrderFront(self: NSWindow, sender: anytype) void {
            self.msgSend(void, "makeKeyAndOrderFront:", .{sender});
        }
    },
);

pub const NSTrackingArea = ExternalClass(
    "NSTrackingArea",
    struct {
        pub const Options = packed struct(u32) {
            // Type of tracking area
            pub const Events = packed struct(u4) {
                /// owner receives mouseEntered when mouse enters area, and mouseExited when mouse leaves area
                mouse_entered_and_exited: bool = false,
                /// owner receives mouseMoved while mouse is within area.  Note that mouseMoved events do not contain userInfo
                mouse_moved: bool = false,
                /// owner receives cursorUpdate when mouse enters area.  Cursor is set appropriately when mouse exits area
                cursor_update: bool = false,

                _: u1 = 0,
            };

            /// When tracking area is active
            pub const Active = enum(u4) {
                none,
                /// owner receives mouseEntered/Exited, mouseMoved, or cursorUpdate when view is first responder
                when_first_responder,
                /// owner receives mouseEntered/Exited, mouseMoved, or cursorUpdate when view is in key window
                in_key_window,
                /// owner receives mouseEntered/Exited, mouseMoved, or cursorUpdate when app is active
                in_active_app,
                /// owner receives mouseEntered/Exited or mouseMoved regardless of activation.  Not supported for NSTrackingCursorUpdate.
                always,
            };

            /// You must specify one or more type from this list in the NSTrackingAreaOptions argument of -initWithRect:options:owner:userInfo:
            events: Events = .{},

            /// You must specify one of the following in the NSTrackingAreaOptions argument of -initWithRect:options:owner:userInfo:
            active: Active = .none,

            // Behavior of tracking area.  These values are used in NSTrackingAreaOptions.  You may specify any number of the following in the NSTrackingAreaOptions argument of -initWithRect:options:owner:userInfo:

            /// generate mouseExited event when mouse leaves area (same as assumeInside argument in deprecated addTrackingRect:owner:userData:assumeInside:)
            assume_inside: bool = false,

            /// tracking occurs in visibleRect of view and rect is ignored
            in_visible_rect: bool = false,

            /// mouseEntered events will be generated as mouse is dragged.  If not set, mouseEntered events will be generated as mouse is moved, and on mouseUp after a drag.  mouseExited events are paired with mouseEntered events so their delivery is affected indirectly.  That is, if a mouseEntered event is generated and the mouse subsequently moves out of the trackingArea, a mouseExited event will be generated whether the mouse is being moved or dragged, independent of this flag.
            enabled_during_mouse_drag: bool = false,

            _: u21 = 0,
        };

        pub fn init(self: NSTrackingArea, rect: cg.Rect, options: Options, owner: NSView, user_data: ?*anyopaque) void {
            self.msgSend(void, "initWithRect:options:owner:userInfo:", .{ rect, options, owner, user_data });
        }
    },
);

test "NSTrackingArea Options" {
    try std.testing.expectEqual(0x001, @as(u32, @bitCast(NSTrackingArea.Options{ .events = .{ .mouse_entered_and_exited = true } })));
    try std.testing.expectEqual(0x002, @as(u32, @bitCast(NSTrackingArea.Options{ .events = .{ .mouse_moved = true } })));
    try std.testing.expectEqual(0x004, @as(u32, @bitCast(NSTrackingArea.Options{ .events = .{ .cursor_update = true } })));

    try std.testing.expectEqual(0x010, @as(u32, @bitCast(NSTrackingArea.Options{ .active = .when_first_responder })));
    try std.testing.expectEqual(0x020, @as(u32, @bitCast(NSTrackingArea.Options{ .active = .in_key_window })));
    try std.testing.expectEqual(0x030, @as(u32, @bitCast(NSTrackingArea.Options{ .active = .in_active_app })));
    try std.testing.expectEqual(0x040, @as(u32, @bitCast(NSTrackingArea.Options{ .active = .always })));

    try std.testing.expectEqual(0x100, @as(u32, @bitCast(NSTrackingArea.Options{ .assume_inside = true })));
    try std.testing.expectEqual(0x200, @as(u32, @bitCast(NSTrackingArea.Options{ .in_visible_rect = true })));
    try std.testing.expectEqual(0x400, @as(u32, @bitCast(NSTrackingArea.Options{ .enabled_during_mouse_drag = true })));
}

pub const NSString = ExternalClass(
    "NSString",
    struct {
        pub fn stringWithUTF8String(text: [:0]const u8) NSString {
            return NSString.class().msgSend(NSString, "stringWithUTF8String:", .{text});
        }
    },
);

pub const NSGraphicsContext = ExternalClass(
    "NSGraphicsContext",
    struct {
        pub fn currentContext() NSGraphicsContext {
            return NSGraphicsContext.class().msgSend(NSGraphicsContext, "currentContext", .{});
        }

        pub fn cgContext(self: NSGraphicsContext) *anyopaque {
            return self.msgSend(*anyopaque, "cgContext", .{});
        }

        pub fn graphicsPort(self: NSGraphicsContext) *anyopaque {
            return self.msgSend(*anyopaque, "graphicsPort", .{});
        }
    },
);

pub const NSNotification = ExternalClass(
    "NSNotification",
    struct {
        pub const Name = *NSString;
    },
);

pub const NSEvent = ExternalClass(
    "NSEvent",
    struct {
        pub fn locationInWindow(self: NSEvent) cg.Point {
            return self.msgSend(cg.Point, "locationInWindow", .{});
        }
    },
);

pub const NSNotificationCenter = ExternalClass(
    "NSNotificationCenter",
    struct {
        pub fn defaultCenter() NSNotificationCenter {
            return NSNotificationCenter.class().msgSend(NSNotificationCenter, "defaultCenter", .{});
        }

        pub fn addObserver(self: NSNotificationCenter, observer: anytype, selector: [:0]const u8, notification: NSNotification.Name, target: anytype) void {
            self.msgSend(void, "addObserver:selector:name:object:", .{ observer, objc.sel(selector), notification, target });
        }
    },
);
