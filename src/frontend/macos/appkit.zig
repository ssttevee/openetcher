const std = @import("std");
const objc = @import("objc");
pub const cg = @import("core_graphics.zig");

const ExternalClass = @import("../../macos/objc.zig").ExternalClass;

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
        /// NSWindowStyleMask
        ///
        /// See https://github.com/hexops/xcode-frameworks/blob/8a1cfb373587ea4c9bb1468b7c986462d8d4e10e/Frameworks/AppKit.framework/Headers/NSWindow.h#L54
        pub const StyleMask = packed struct(u32) {
            titled: bool = false,
            closable: bool = false,
            miniaturizable: bool = false,
            resizable: bool = false,

            /// Only applicable for \c NSPanel (or a subclass thereof).
            utility_window: bool = false,

            _0: u1 = 0,

            /// Only applicable for \c NSPanel (or a subclass thereof).
            doc_modal_window: bool = false,

            /// Specifies that a panel that does not activate the owning application. Only applicable for \c NSPanel (or a subclass thereof).
            non_activating_panel: bool = false,

            /// Textured window style is deprecated and should no longer be used. Specifies a window with textured background. Textured windows generally don't draw a top border line under the titlebar/toolbar. To get that line, use the \c NSUnifiedTitleAndToolbarWindowMask mask.
            textured_background: bool = false,

            _1: u3 = 0,

            /// Specifies a window whose titlebar and toolbar have a unified look - that is, a continuous background. Under the titlebar and toolbar a horizontal separator line will appear.
            unified_title_and_toolbar: bool = false,

            /// Specifies a heads up display panel.  Only applicable for \c NSPanel (or a subclass thereof).
            hud_window: bool = false,

            /// When present, the window will appear full screen. This mask is automatically toggled when \c -toggleFullScreen: is called.
            fullscreen: bool = false,

            /// If set, the \c contentView will consume the full size of the window; it can be combined with other window style masks, but is only respected for windows with a titlebar. Utilizing this mask opts-in to layer-backing. Utilize the \c contentLayoutRect or auto-layout \c contentLayoutGuide to layout views underneath the titlebar/toolbar area.
            full_size_content_view: bool = false,

            _2: u16 = 0,

            test {
                try std.testing.expectEqual(1 << 0, @as(u32, @bitCast(StyleMask{ .titled = true })));
                try std.testing.expectEqual(1 << 1, @as(u32, @bitCast(StyleMask{ .closable = true })));
                try std.testing.expectEqual(1 << 2, @as(u32, @bitCast(StyleMask{ .miniaturizable = true })));
                try std.testing.expectEqual(1 << 3, @as(u32, @bitCast(StyleMask{ .resizable = true })));
                try std.testing.expectEqual(1 << 4, @as(u32, @bitCast(StyleMask{ .utility_window = true })));
                try std.testing.expectEqual(1 << 6, @as(u32, @bitCast(StyleMask{ .doc_modal_window = true })));
                try std.testing.expectEqual(1 << 7, @as(u32, @bitCast(StyleMask{ .non_activating_panel = true })));
                try std.testing.expectEqual(1 << 8, @as(u32, @bitCast(StyleMask{ .textured_background = true })));
                try std.testing.expectEqual(1 << 12, @as(u32, @bitCast(StyleMask{ .unified_title_and_toolbar = true })));
                try std.testing.expectEqual(1 << 13, @as(u32, @bitCast(StyleMask{ .hud_window = true })));
                try std.testing.expectEqual(1 << 14, @as(u32, @bitCast(StyleMask{ .fullscreen = true })));
                try std.testing.expectEqual(1 << 15, @as(u32, @bitCast(StyleMask{ .full_size_content_view = true })));
            }
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

        pub fn setTitlebarAppearsTransparent(self: NSWindow, titlebarAppearsTransparent: bool) void {
            self.msgSend(void, "setTitlebarAppearsTransparent:", .{titlebarAppearsTransparent});
        }
    },
);

test {
    _ = NSWindow.StyleMask;
}

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

            test {
                try std.testing.expectEqual(0x001, @as(u32, @bitCast(Options{ .events = .{ .mouse_entered_and_exited = true } })));
                try std.testing.expectEqual(0x002, @as(u32, @bitCast(Options{ .events = .{ .mouse_moved = true } })));
                try std.testing.expectEqual(0x004, @as(u32, @bitCast(Options{ .events = .{ .cursor_update = true } })));

                try std.testing.expectEqual(0x010, @as(u32, @bitCast(Options{ .active = .when_first_responder })));
                try std.testing.expectEqual(0x020, @as(u32, @bitCast(Options{ .active = .in_key_window })));
                try std.testing.expectEqual(0x030, @as(u32, @bitCast(Options{ .active = .in_active_app })));
                try std.testing.expectEqual(0x040, @as(u32, @bitCast(Options{ .active = .always })));

                try std.testing.expectEqual(0x100, @as(u32, @bitCast(Options{ .assume_inside = true })));
                try std.testing.expectEqual(0x200, @as(u32, @bitCast(Options{ .in_visible_rect = true })));
                try std.testing.expectEqual(0x400, @as(u32, @bitCast(Options{ .enabled_during_mouse_drag = true })));
            }
        };

        pub fn init(self: NSTrackingArea, rect: cg.Rect, options: Options, owner: NSView, user_data: ?*anyopaque) void {
            self.msgSend(void, "initWithRect:options:owner:userInfo:", .{ rect, options, owner, user_data });
        }
    },
);

test "NSTrackingArea.Options" {
    _ = NSTrackingArea.Options;
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

pub const NSCursor = ExternalClass(
    "NSCursor",
    struct {
        /// Returns the pointing-hand system cursor.
        pub fn pointingHandCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "pointingHandCursor", .{});
        }

        /// Returns the default cursor, the arrow cursor.
        pub fn arrowCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "arrowCursor", .{});
        }

        /// Returns the contextual menu system cursor.
        pub fn contextualMenuCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "contextualMenuCursor", .{});
        }

        /// Returns the closed-hand system cursor.
        pub fn closedHandCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "closedHandCursor", .{});
        }

        /// Returns the cross-hair system cursor.
        pub fn crosshairCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "crosshairCursor", .{});
        }

        /// Returns a cursor indicating that the current operation will result in a disappearing item.
        pub fn disappearingItemCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "disappearingItemCursor", .{});
        }

        /// Returns a cursor indicating that the current operation will result in a copy action.
        pub fn dragCopyCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "dragCopyCursor", .{});
        }

        /// Returns a cursor indicating that the current operation will result in a link action.
        pub fn dragLinkCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "dragLinkCursor", .{});
        }

        /// Returns a cursor that looks like a capital I with a tiny crossbeam at its middle.
        pub fn iBeamCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "iBeamCursor", .{});
        }

        /// Returns the open-hand system cursor.
        pub fn openHandCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "openHandCursor", .{});
        }

        /// Returns the operation not allowed cursor.
        pub fn operationNotAllowedCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "operationNotAllowedCursor", .{});
        }

        /// Returns the resize-down system cursor.
        pub fn resizeDownCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "resizeDownCursor", .{});
        }

        /// Returns the resize-left system cursor.
        pub fn resizeLeftCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "resizeLeftCursor", .{});
        }

        /// Returns the resize-left-and-right system cursor.
        pub fn resizeLeftRightCursor() NSCursor {
            return NSCursor.class().msgSend(NSCursor, "resizeLeftRightCursor", .{});
        }

        pub fn set(self: NSCursor) void {
            self.msgSend(void, "set", .{});
        }
    },
);
