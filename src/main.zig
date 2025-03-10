const std = @import("std");
const objc = @import("objc");
const c = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const NSApplicationActivationPolicy = enum(u32) {
    regular = 0,
    accessory = 1,
    err = 2,
};

const NSWindowStyleMask = packed struct(u32) {
    titled: bool = false,
    closable: bool = false,
    miniaturizable: bool = false,
    resizable: bool = false,
    _: u28 = 0,
};

const NSBackingStoreType = enum(u32) {
    buffered = 2,
};

extern fn NSRectFill(rect: c.CGRect) callconv(.C) void;

const AppDelegate = extern struct {
    isa: objc.Class,

    window: objc.Object,

    pub var class: ?objc.Class = null;

    pub fn applicationDidFinishLaunching(id: *AppDelegate, _: objc.Sel) bool {
        const self = @as(*AppDelegate, @ptrCast(id));

        const NSWindow = objc.getClass("NSWindow") orelse unreachable;
        const NSString = objc.getClass("NSString") orelse unreachable;
        const CustomViewClass = CustomView.class orelse unreachable;

        self.window = NSWindow.msgSend(objc.Object, "alloc", .{});
        self.window.msgSend(void, "initWithContentRect:styleMask:backing:defer:", .{
            c.CGRect{
                .origin = .{
                    .x = 0,
                    .y = 0,
                },
                .size = .{
                    .width = 600,
                    .height = 600,
                },
            },
            NSWindowStyleMask{
                .titled = true,
                .closable = true,
                .miniaturizable = true,
                .resizable = true,
            },
            NSBackingStoreType.buffered,
            false,
        });

        const view = CustomViewClass.msgSend(objc.Object, "alloc", .{});
        view.msgSend(void, "initWithFrame:", .{
            c.CGRect{
                .origin = .{
                    .x = 14,
                    .y = 14,
                },
                .size = .{
                    .width = 320,
                    .height = 480,
                },
            },
        });

        self.window.msgSend(void, "setContentView:", .{view});
        self.window.msgSend(void, "becomeFirstResponder", .{});

        const title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Pure Zig App"});

        self.window.msgSend(void, "setTitle:", .{title});
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{null});

        return true;
    }
};

const CustomView = extern struct {
    pub var class: ?objc.Class = null;

    pub const ivars = struct {
        color: [*c]const u8,

        fn get(instance: objc.Object, comptime field: std.meta.FieldEnum(ivars)) std.meta.FieldType(@This(), field) {
            var value: ?std.meta.FieldType(@This(), field) = undefined;
            _ = objc.c.object_getInstanceVariable(instance.value, @tagName(field), @ptrCast(&value));
            return value.?;
        }

        fn set(instance: objc.Object, comptime field: std.meta.FieldEnum(ivars), value: ?std.meta.FieldType(@This(), field)) void {
            _ = objc.c.object_setInstanceVariable(instance.value, @tagName(field), @constCast(@ptrCast(value)));
        }
    };

    pub fn drawRect(self: objc.Object, _: objc.Sel, _: c.CGRect) void {
        const NSColor = objc.getClass("NSColor") orelse unreachable;

        var color: objc.Object = undefined;
        const color_str = ivars.get(self, .color);
        std.debug.print("ivar color {*}\n", .{color_str});
        if (color_str != 0) {
            color = NSColor.msgSend(objc.Object, std.mem.sliceTo(color_str, 0), .{});
        } else {
            color = NSColor.msgSend(objc.Object, "redColor", .{});
        }

        color.msgSend(void, "set", .{});

        NSRectFill(.{
            .origin = .{
                .x = 21,
                .y = 21,
            },
            .size = .{
                .width = 210,
                .height = 210,
            },
        });
    }

    pub fn mouseDown(self: objc.Object, _: objc.Sel, event: objc.Object) void {
        std.debug.print("mouse down {any}\n", .{event});
        self.msgSend(void, "setNeedsDisplay:", .{true});
        ivars.set(self, .color, "blueColor");
    }

    pub fn mouseUp(self: objc.Object, _: objc.Sel, event: objc.Object) void {
        std.debug.print("mouse up {any}\n", .{event});
        self.msgSend(void, "setNeedsDisplay:", .{true});
        ivars.set(self, .color, null);
    }
};

pub fn main() !void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const NSView = objc.getClass("NSView").?;
    const NSApplication = objc.getClass("NSApplication").?;
    // const NSWindow = objc.getClass("NSWindow").?;
    // const NSString = objc.getClass("NSString").?;

    const AppDelegateClass = objc.Class.registerStruct(AppDelegate, NSObject).?;
    _ = objc.Class.registerStruct(CustomView, NSView).?;
    // const AppDelegateClass = objc.allocateClassPair(NSObject, "AppDelegate").?;
    // _ = AppDelegateClass.addMethod(
    //     "applicationDidFinishLaunching:",
    //     AppDelegate.applicationDidFinishLaunching,
    // ) catch unreachable;
    // objc.registerClassPair(AppDelegateClass);

    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "setActivationPolicy:", .{0});

    const app_del = AppDelegateClass.msgSend(objc.Object, "alloc", .{});
    app_del.msgSend(void, "init", .{});

    // const window = NSWindow.msgSend(objc.Object, "alloc", .{});
    // window.msgSend(void, "initWithContentRect:styleMask:backing:defer:", .{
    //     c.CGRect{
    //         .origin = .{
    //             .x = 0,
    //             .y = 0,
    //         },
    //         .size = .{
    //             .width = 600,
    //             .height = 600,
    //         },
    //     },
    //     NSWindowStyleMask{
    //         .titled = true,
    //         .closable = true,
    //         .resizable = true,
    //     },
    //     NSBackingStoreType.buffered,
    //     false,
    // });
    // window.msgSend(void, "setTitle:", .{title});
    // window.msgSend(void, "makeKeyAndOrderFront:", .{null});

    app.msgSend(void, "setDelegate:", .{app_del});
    app.msgSend(void, "activateIgnoringOtherApps:", .{true});
    app.msgSend(void, "run", .{});
}
