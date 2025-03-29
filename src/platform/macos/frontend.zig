const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const clay = @import("clay");
const cairo = @import("cairo");
const common = @import("../frontend.zig");
const renderer = @import("../../renderer.zig");

const CustomClass = @import("objc.zig").CustomClass;
const NSNumber = @import("common.zig").NSNumber;

extern fn CGContextTranslateCTM(cg_context: *anyopaque, tx: f64, ty: f64) void;
extern fn CGContextScaleCTM(cg_context: *anyopaque, sx: f64, sy: f64) void;

pub fn App(comptime T: type, layoutFn: fn (app_state: *T) clay.RenderCommandArray) type {
    return struct {
        const State = common.AppState(T);

        const AppDelegate = CustomClass(
            appkit.NSObject,
            struct {
                const Configuration = struct {
                    initial_width: f64,
                    initial_height: f64,
                };

                pub const ivars = struct {
                    config: Configuration,
                };

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

                // pub fn windowWillClose(self: AppDelegate, _: objc.Sel, _: appkit.NSNotification) void {
                //     _ = self;

                //     // std.debug.print("window is closing\n", .{});
                // }

                pub fn applicationDidFinishLaunching(self: AppDelegate, _: objc.Sel) bool {
                    const main_screen = appkit.NSScreen.mainScreen();
                    const screen_rect = main_screen.visibleFrame();

                    const window_size = appkit.cg.Size{
                        .width = 800,
                        .height = 480,
                    };

                    const window = appkit.NSWindow.alloc();
                    window.init(
                        .{
                            .origin = .{
                                .x = (screen_rect.size.width - window_size.width) / 2,
                                .y = (screen_rect.size.height - window_size.height) / 2,
                            },
                            .size = window_size,
                        },
                        .{
                            .titled = true,
                            .closable = true,
                            .miniaturizable = true,
                            .resizable = true,
                            .unified_title_and_toolbar = true,
                            .full_size_content_view = true,
                        },
                        .buffered,
                        false,
                    );

                    const view_size: appkit.cg.Size = .{
                        .width = 320,
                        .height = 480,
                    };

                    common.initClayContext(convertDimensions(view_size)) catch unreachable;

                    const view = CustomView.init(.{
                        .origin = .{
                            .x = 0,
                            .y = 0,
                        },
                        .size = view_size,
                    });

                    window.setContentView(view);
                    window.becomeFirstResponder();

                    // const title = appkit.NSString.stringWithUTF8String("OpenEtcher");

                    // window.setTitle(title);
                    window.makeKeyAndOrderFront(null);
                    window.setTitlebarAppearsTransparent(true);

                    // appkit.NSNotificationCenter.defaultCenter().addObserver(self, "windowWillClose:", appkit.NSWindowWillCloseNotification, window);

                    self.setWindow(window);

                    return true;
                }
            },
        );

        const CustomView = CustomClass(
            appkit.NSView,
            struct {
                pub const ivars = struct {
                    state: State,
                };

                pub fn init(frame: appkit.cg.Rect) CustomView {
                    const self = CustomView.alloc();
                    self.super().initWithFrame(frame);

                    const view_state = std.heap.page_allocator.create(State) catch unreachable;
                    view_state.* = .{
                        .common = .{
                            .redraw_ptr = @ptrCast(self.object.value),
                            .redraw_fn = struct {
                                fn redraw(ptr: ?*anyopaque) void {
                                    const view: CustomView = .{ .object = .{ .value = @alignCast(@ptrCast(ptr)) } };
                                    const ismain = appkit.NSThread.isMainThread();
                                    if (ismain) {
                                        view.msgSend(void, "setNeedsDisplay:", .{true});
                                    } else {
                                        view.msgSend(void, "performSelectorOnMainThread:withObject:waitUntilDone:", .{ objc.sel("setNeedsDisplay:"), NSNumber.numberWithBool(true), false });
                                    }
                                }
                            }.redraw,
                        },
                    };

                    self.ivarSet(.state, view_state);

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
                    return self.ivarGet(.state).?;
                }

                pub inline fn setNeedsDisplay(self: CustomView, needs_display: bool) void {
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
                    clay.setPointerState(self.getPointerPosition(event), self.state().common.mouse_down);
                    // self.setNeedsDisplay(true);
                }

                pub fn mouseDown(self: CustomView, _: objc.Sel, event: appkit.NSEvent) void {
                    self.state().common.mouse_down = true;
                    // not sure why this needs to be called twice to take effect for onHover
                    clay.setPointerState(self.getPointerPosition(event), true);
                    clay.setPointerState(self.getPointerPosition(event), true);
                    // self.setNeedsDisplay(true);
                }

                pub fn mouseUp(self: CustomView, _: objc.Sel, event: appkit.NSEvent) void {
                    self.state().common.mouse_down = false;
                    // not sure why this needs to be called twice to take effect for onHover
                    clay.setPointerState(self.getPointerPosition(event), false);
                    clay.setPointerState(self.getPointerPosition(event), false);
                    // self.setNeedsDisplay(true);
                }

                pub fn drawRect(self: CustomView, _: objc.Sel, _: appkit.cg.Rect) void {
                    if (self.ivarGet(.state)) |s| {
                        if (s.common.first_draw) {
                            s.common.first_draw = false;

                            s.data.setState(.default);
                        }
                    }

                    const bounds = self.super().bounds();
                    common.setLayoutDimensions(convertDimensions(bounds.size)) catch unreachable;

                    // self.super().lockFocus();
                    // defer self.super().unlockFocus();

                    const cg_ctx = appkit.NSGraphicsContext.currentContext().graphicsPort();
                    CGContextTranslateCTM(cg_ctx, 0.0, bounds.size.height);
                    CGContextScaleCTM(cg_ctx, 1.0, -1.0);

                    const surface = cairo.Surface.initQuartzContext(cg_ctx, @intFromFloat(bounds.size.width), @intFromFloat(bounds.size.height)) catch unreachable;
                    defer surface.deinit();

                    const cairo_ctx = cairo.Context.init(surface) catch unreachable;
                    defer cairo_ctx.deinit();

                    renderer.initialize(cairo_ctx);

                    common.render(layoutFn(&self.state().data));
                }
            },
        );

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

        pub inline fn run() void {
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

        pub const redraw = State.redraw;
    };
}
