const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const clay = @import("clay");
const cairo = @import("cairo");

const CustomClass = @import("objc.zig").CustomClass;

const fonts: []const [*]const u8 = &[_][*]const u8{
    "Callistoga",
    "Quicksand Semibold",
};

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
            const window = appkit.NSWindow.alloc();
            window.init(
                .{
                    .origin = .{
                        .x = 100,
                        .y = 100,
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

            const view_size: appkit.cg.Size = .{
                .width = 320,
                .height = 480,
            };

            _ = clay.Context.init(std.heap.page_allocator, convertDimensions(view_size), error_handler) catch unreachable;
            clay.setMeasureTextFunction(clay.renderers.cairo.measureText, @constCast(@ptrCast(fonts.ptr)));

            const view = CustomView.init(.{
                .origin = .{
                    .x = 14,
                    .y = 14,
                },
                .size = view_size,
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
        const State = extern struct {
            mouse_down: bool = false,
        };

        pub const ivars = struct {
            state: *State,

            fn get(instance: objc.Object, comptime field: std.meta.FieldEnum(ivars)) std.meta.FieldType(@This(), field) {
                var value: ?std.meta.FieldType(@This(), field) = undefined;
                _ = objc.c.object_getInstanceVariable(instance.value, @tagName(field), @ptrCast(&value));
                return value.?;
            }

            fn set(instance: objc.Object, comptime field: std.meta.FieldEnum(ivars), value: ?std.meta.FieldType(@This(), field)) void {
                _ = objc.c.object_setInstanceVariable(instance.value, @tagName(field), @constCast(@ptrCast(value)));
            }
        };

        pub fn init(frame: appkit.cg.Rect) CustomView {
            const self = CustomView.alloc();
            self.super().initWithFrame(frame);

            const view_state = std.heap.page_allocator.create(State) catch unreachable;
            view_state.* = .{};

            ivars.set(self.object, .state, view_state);

            const tracking_area = appkit.NSTrackingArea.alloc();
            tracking_area.init(
                self.super().visibleRect(),
                .{ .events = .{ .mouse_entered_and_exited = true, .mouse_moved = true }, .active = .in_active_app },
                self.super(),
                null,
            );
            self.super().addTrackingArea(tracking_area);

            return self;
        }

        pub fn state(self: CustomView) *State {
            return ivars.get(self.object, .state);
        }

        pub fn setNeedsDisplay(self: CustomView, needs_display: bool) void {
            self.msgSend(void, "setNeedsDisplay:", .{needs_display});
        }

        fn getPointerPosition(self: CustomView, event: appkit.NSEvent) clay.Vector2 {
            const p = event.locationInWindow();
            return convertVector(.{
                .x = p.x,
                .y = (p.y - self.super().bounds().size.height) * -1,
            });
        }

        pub fn mouseMoved(self: CustomView, _: objc.Sel, event: appkit.NSEvent) void {
            self.setNeedsDisplay(true);
            clay.setPointerState(self.getPointerPosition(event), self.state().mouse_down);
        }

        pub fn mouseDown(self: CustomView, _: objc.Sel, event: appkit.NSEvent) void {
            self.setNeedsDisplay(true);
            self.state().mouse_down = true;
            clay.setPointerState(self.getPointerPosition(event), false);
        }

        pub fn mouseUp(self: CustomView, _: objc.Sel, event: appkit.NSEvent) void {
            self.setNeedsDisplay(true);
            self.state().mouse_down = false;
            clay.setPointerState(self.getPointerPosition(event), false);
        }

        pub fn drawRect(self: CustomView, _: objc.Sel, _: appkit.cg.Rect) void {
            const bounds = self.super().bounds();
            if (reinitialize_clay) {
                clay.Context.getCurrent().?.deinit(std.heap.page_allocator);
                _ = clay.Context.init(std.heap.page_allocator, convertDimensions(bounds.size), error_handler) catch unreachable;
                reinitialize_clay = false;
            } else {
                clay.setLayoutDimensions(convertDimensions(bounds.size));
            }

            // self.super().lockFocus();
            // defer self.super().unlockFocus();

            const cg_ctx = appkit.NSGraphicsContext.currentContext().graphicsPort();
            CGContextTranslateCTM(cg_ctx, 0.0, bounds.size.height);
            CGContextScaleCTM(cg_ctx, 1.0, -1.0);

            const surface = cairo.Surface.initQuartzContext(cg_ctx, @intFromFloat(bounds.size.width), @intFromFloat(bounds.size.height)) catch unreachable;
            defer surface.deinit();

            const cairo_ctx = cairo.Context.init(surface) catch unreachable;
            defer cairo_ctx.deinit();

            clay.renderers.cairo.initialize(cairo_ctx);

            clay.renderers.cairo.render(createLayout(self.state()), @ptrCast(fonts.ptr));
        }
    },
);

extern fn CGContextTranslateCTM(cg_context: *anyopaque, tx: f64, ty: f64) void;
extern fn CGContextScaleCTM(cg_context: *anyopaque, sx: f64, sy: f64) void;

fn createLayout(state: *const CustomView.State) clay.RenderCommandArray {
    return clay.layout()({
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
                .child_alignment = .center,
            },
            .background_color = clay.Color.black,
        })({
            clay.ui()(.{
                .id = clay.id("box"),
                .layout = .{
                    .sizing = .fixed(40),
                },
                .background_color = if (state.mouse_down) .rgb(0, 255, 0) else if (clay.isHovered()) .rgb(255, 0, 0) else clay.Color.white,
            })({});
        });
    });
}

var reinitialize_clay = false;

inline fn convertDimensions(size: appkit.cg.Size) clay.Dimensions {
    return .{
        .width = @floatCast(size.width),
        .height = @floatCast(size.height),
    };
}

inline fn convertVector(p: appkit.cg.Point) clay.Vector2 {
    return .{
        .x = @floatCast(p.x),
        .y = @floatCast(p.y),
    };
}

fn handleClayErrors(error_data: clay.ErrorData) callconv(.C) void {
    std.log.err("{s}", .{error_data.error_text.asSlice()});
    switch (error_data.error_type) {
        .elements_capacity_exceeded => {
            reinitialize_clay = true;
            clay.setMaxElementCount(clay.getMaxElementCount() * 2);
        },
        .text_measurement_capacity_exceeded => {
            reinitialize_clay = true;
            clay.setMaxMeasureTextCacheWordCount(clay.getMaxMeasureTextCacheWordCount() * 2);
        },
        else => {},
    }
}

const error_handler: clay.ErrorHandler = .{ .handler = handleClayErrors };

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

test {
    std.testing.refAllDeclsRecursive(@This());
}
