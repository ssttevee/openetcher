const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");

const CustomClass = @import("objc.zig").CustomClass;

const AppDelegate = CustomClass(
    appkit.NSObject,
    struct {
        pub fn init(self: AppDelegate) void {
            self.msgSend(void, "init", .{});
        }

        pub fn setWindow(self: AppDelegate, window: appkit.NSWindow) void {
            self.msgSend(void, "setWindow:", .{window});
        }

        pub fn applicationShouldTerminateAfterLastWindowClosed(self: AppDelegate, _: objc.Sel) bool {
            _ = self;

            // std.debug.print("applicationShouldTerminateAfterLastWindowClosed {s}\n", .{});

            return true;
        }

        pub fn windowWillClose(self: AppDelegate, _: objc.Sel, _: appkit.NSNotification) void {
            _ = self;

            std.debug.print("window is closing\n", .{});
        }

        pub fn applicationDidFinishLaunching(self: AppDelegate, _: objc.Sel) bool {
            // const self = @as(*AppDelegate, @ptrCast(id));

            // const NSWindow = objc.getClass("NSWindow") orelse unreachable;
            // const NSString = objc.getClass("NSString") orelse unreachable;
            // const CustomViewClass = CustomView.class orelse unreachable;

            // self.window = NSWindow.msgSend(objc.Object, "alloc", .{});
            const window = appkit.NSWindow.alloc();
            window.init(
                .{
                    .origin = .{
                        .x = 0,
                        .y = 0,
                    },
                    .size = .{
                        .width = 600,
                        .height = 600,
                    },
                },
                .{
                    .titled = true,
                    .closable = true,
                    .miniaturizable = true,
                    .resizable = true,
                },
                .buffered,
                false,
            );

            const view = CustomView.alloc();
            view.super().initWithFrame(.{
                .origin = .{
                    .x = 14,
                    .y = 14,
                },
                .size = .{
                    .width = 320,
                    .height = 480,
                },
            });

            window.setContentView(view);
            window.becomeFirstResponder();

            const title = appkit.NSString.stringWithUTF8String("Pure Zig App");

            window.setTitle(title);
            window.makeKeyAndOrderFront(null);

            appkit.NSNotificationCenter.defaultCenter().addObserver(self, "windowWillClose:", appkit.NSWindowWillCloseNotification, window);

            self.setWindow(window);

            return true;
        }
    },
);

const CustomView = CustomClass(
    appkit.NSView,
    struct {
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

        pub fn setNeedsDisplay(self: CustomView, needs_display: bool) void {
            self.msgSend(void, "setNeedsDisplay:", .{needs_display});
        }

        pub fn drawRect(self: CustomView, _: objc.Sel, _: appkit.cg.Rect) void {
            const color_str = ivars.get(self.object, .color);
            std.debug.print("ivar color {*}\n", .{color_str});

            appkit.NSColor.classMsgSend(appkit.NSColor, if (color_str == 0) "redColor" else std.mem.sliceTo(color_str, 0), .{}).set();

            appkit.NSRectFill(.{
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

        pub fn mouseDown(self: CustomView, _: objc.Sel, event: objc.Object) void {
            std.debug.print("mouse down {any}\n", .{event});
            self.setNeedsDisplay(true);
            ivars.set(self.object, .color, "blueColor");
        }

        pub fn mouseUp(self: CustomView, _: objc.Sel, event: objc.Object) void {
            std.debug.print("mouse up {any}\n", .{event});
            self.setNeedsDisplay(true);
            ivars.set(self.object, .color, null);
        }
    },
);

pub fn main() !void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const app = appkit.NSApplication.sharedApplication();
    app.setActivationPolicy(.regular);

    const delegate = AppDelegate.alloc();
    delegate.init();

    app.setDelegate(delegate);
    app.activateIgnoringOtherApps(true);
    app.run();
}
