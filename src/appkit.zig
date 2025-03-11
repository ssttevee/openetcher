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
        pub fn current() NSGraphicsContext {
            return NSGraphicsContext.class().msgSend(NSGraphicsContext, "current", .{});
        }

        pub fn cgContext(self: NSGraphicsContext) *anyopaque {
            return self.msgSend(*anyopaque, "cgContext", .{});
        }
    },
);

pub const NSNotification = ExternalClass(
    "NSNotification",
    struct {
        pub const Name = *anyopaque;
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
