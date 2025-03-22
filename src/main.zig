const std = @import("std");
const clay = @import("clay");

const drivelist = @import("drivelist.zig");
const frontend = @import("frontend.zig");
const svg = @import("svg.zig");

const colors = struct {
    const bg = clay.Color.rgb(76, 80, 91);
    const btn = clay.Color.transparent;
    const btn_text = clay.Color.white.withAlpha(170);
    const highlighted_btn = clay.Color.rgb(0, 135, 158);
    const highlighted_btn_text = clay.Color.white;
    const disabled_btn = clay.Color.rgb(55, 60, 63);
    const disabled_btn_text = clay.Color.white.withAlpha(85);

    const loading_bar_bg = clay.Color.rgb(198, 200, 189);
    const loading_bar_fg = clay.Color.rgb(39, 202, 32);
};

const FrontPage = struct {
    current_step: u8 = 0,
    highlighted_button: u8 = 0,
    prev_highlighted_button: u8 = 0,
    hovering_button: bool = false,
    prev_hovering: bool = false,

    const step_buttons = [_][]const [2][]const u8{
        &[_][2][]const u8{
            .{ "ImageFromFileButton", "Flash from file" },
            .{ "ImageFromURLButton", "Flash from URL" },
            .{ "ImageFromDiskButton", "Clone a disk" },
        },
        &[_][2][]const u8{
            .{ "SelectTargetButton", "Select Target" },
        },
        &[_][2][]const u8{
            .{ "FlashButton", "Flash!" },
        },
    };

    inline fn parentState(self: *FrontPage) *MyState {
        return @as(*MyState, @alignCast(@fieldParentPtr("front_page", self)));
    }

    fn buttonColor(state: *const FrontPage, step_number: u8, button_number: u8) clay.Color {
        if (state.current_step != step_number) {
            return colors.disabled_btn;
        }

        if (state.highlighted_button == button_number) {
            return colors.highlighted_btn;
        }

        return colors.btn;
    }

    const btn_text_size = 14;

    fn buttonTextConfig(state: *const FrontPage, comptime step_number: u8, comptime button_number: u8) *const clay.TextElementConfig {
        if (state.current_step != step_number) {
            return comptime &.{ .font_size = btn_text_size, .text_color = colors.disabled_btn_text };
        }

        if (state.hovering_button and state.highlighted_button == button_number) {
            return comptime &.{ .font_size = btn_text_size, .text_color = colors.highlighted_btn_text };
        }

        return comptime &.{ .font_size = btn_text_size, .text_color = colors.btn_text };
    }

    fn getButtonIndex(comptime step_number: u8, comptime button_number: u8) usize {
        return switch (step_number) {
            0 => switch (button_number) {
                0, 1, 2 => button_number,
                else => unreachable,
            },
            1, 2 => step_number + 2,
            else => unreachable,
        };
    }

    inline fn buttonLayout(state: *FrontPage, comptime step_number: u8, comptime button_number: u8, comptime element_id_label: []const u8, comptime button_text: []const u8) void {
        clay.ui()(.{
            .id = clay.id(element_id_label),
            .layout = .{
                .sizing = .{
                    .width = .grow(.{}),
                },
                .padding = .y(16),
                .child_alignment = .center,
            },
            .background_color = state.buttonColor(step_number, button_number),
            .corner_radius = .all(22),
        })({
            clay.text(button_text, state.buttonTextConfig(step_number, button_number));
        });
    }

    inline fn createLayout(state: *FrontPage) void {
        clay.setOnHover(onHoverButtonStack, @ptrCast(state));

        clay.ui()(.{
            .layout = .{
                .sizing = .{ .width = .grow(.{}) },
                .padding = .{
                    .top = 16,
                    .bottom = 80,
                },
                .child_alignment = .center,
            },
        })({
            clay.text("OpenEtcher", comptime &.{ .font_size = 16, .text_color = .white });
        });

        clay.ui()(.{
            .layout = .{
                .sizing = .{ .width = .grow(.{}) },
                .child_alignment = .center,
                .child_gap = 44,
            },
        })({
            clay.ui()(.{
                .id = clay.id("ImageIcon"),
                .layout = .{
                    .sizing = .fixed(60),
                    .child_alignment = .center,
                },
            })({
                svg.clayImage(.add_document, 10, .white, .fixed(42));
            });
            clay.ui()(.{
                .layout = .{
                    .sizing = .{
                        .width = .fixed(100),
                        .height = .fixed(2),
                    },
                },
                .background_color = .rgba(255, 255, 255, 127),
            })({});
            clay.ui()(.{
                .id = clay.id("DiskIcon"),
                .layout = .{
                    .sizing = .fixed(60),
                    .child_alignment = .center,
                },
            })({
                svg.clayImage(.hdd, 10, .white, .fixed(42));
            });
            clay.ui()(.{
                .layout = .{
                    .sizing = .{
                        .width = .fixed(100),
                        .height = .fixed(2),
                    },
                },
                .background_color = .rgba(255, 255, 255, 127),
            })({});
            clay.ui()(.{
                .id = clay.id("FlashIcon"),
                .layout = .{
                    .sizing = .fixed(60),
                    .child_alignment = .center,
                },
            })({
                svg.clayImage(.bolt, 10, .white, .fixed(42));
            });
        });

        clay.ui()(.{
            .layout = .{
                .sizing = .{ .width = .grow(.{}) },
                .child_alignment = .top_center,
                .child_gap = 48,
            },
        })({
            inline for (step_buttons, 0..) |buttons, step_number| {
                clay.ui()(.{
                    .layout = .{
                        .sizing = .{ .width = .fixed(200) },
                        .layout_direction = .top_to_bottom,
                    },
                })({
                    inline for (buttons, 0..) |btn, btn_number| {
                        state.buttonLayout(step_number, btn_number, btn[0], btn[1]);
                    }
                });
            }
        });
    }

    fn onHoverButtonStack(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
        _ = element_id;

        const state: *FrontPage = @alignCast(@ptrCast(user_data));
        if (state.parentState().* != .front_page) {
            return;
        }

        state.highlighted_button, state.hovering_button = blk: {
            for (step_buttons[state.current_step], 0..) |btn, btn_number| {
                if (clay.getElementData(clay.getElementId(btn[0]))) |element_data| {
                    if (element_data.bounding_box.contains(pointer_data.position)) {
                        break :blk .{ @intCast(btn_number), true };
                    }
                }
            }

            break :blk .{ 0, false };
        };

        if (state.prev_highlighted_button != state.highlighted_button) {
            state.prev_highlighted_button = state.highlighted_button;
            state.parentState().redraw();
        }

        if (state.prev_hovering != state.hovering_button) {
            state.prev_hovering = state.hovering_button;
            state.parentState().redraw();

            frontend.platform.setCursor(if (state.hovering_button) .pointer else .default);
        }

        switch (pointer_data.state) {
            .released_this_frame => {
                if (state.hovering_button) {
                    // TODO: handle button click
                    // std.debug.print("button {d} onmouseup\n", .{state.highlighted_button});
                    if (state.current_step == 2) {
                        state.parentState().setState(.{ .flashing = .{ .total = 1000000000 } });

                        frontend.platform.setCursor(.default);
                    } else if (state.current_step < step_buttons.len - 1) {
                        state.current_step += 1;
                    }

                    state.parentState().redraw();
                }
            },
            // .pressed_this_frame => {
            //     if (state.hovering_button) {
            //         // TODO: handle button click
            //         std.debug.print("button {d} onmousedown\n", .{state.highlighted_button});
            //     }
            // },
            else => {},
        }

        // std.debug.print("pointer_data.state {any}\n", .{pointer_data.state});
    }
};

const HumanizeBytesPerSecond = struct {
    bytes_per_second: f64,

    const units = [_][]const u8{
        "B/s",
        "KB/s",
        "MB/s",
        "GB/s",
        "TB/s",
        "PB/s",
        "EB/s",
    };

    pub fn format(self: HumanizeBytesPerSecond, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const unit, const num = blk: {
            if (!std.math.isNormal(self.bytes_per_second)) {
                break :blk .{ units[0], @as(f64, 0.0) };
            }
            inline for (units, 0..) |unit, i| {
                const magnitude = comptime std.math.pow(f64, 1000, i);
                if (self.bytes_per_second < magnitude * 1000 or i == units.len - 1) {
                    break :blk .{ unit, self.bytes_per_second / magnitude };
                }
            }
        };

        try std.fmt.format(writer, "{d:" ++ fmt ++ "}{s}", .{ num, unit });
    }
};

const HumanizeDuration = struct {
    seconds: f64,

    pub fn format(self: HumanizeDuration, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const unit, const num = blk: {
            if (!std.math.isNormal(self.seconds)) {
                break :blk .{ "s", @as(f64, 0.0) };
            }

            if (self.seconds < 0.000001) {
                break :blk .{ "ns", self.seconds / 1000000000.0 };
            }

            if (self.seconds < 0.001) {
                break :blk .{ "us", self.seconds / 1000000.0 };
            }

            if (self.seconds < 1) {
                break :blk .{ "ms", self.seconds / 1000.0 };
            }

            if (self.seconds < 60) {
                break :blk .{ "seconds", self.seconds };
            }

            if (self.seconds < 3600) {
                break :blk .{ "minutes", self.seconds / 60.0 };
            }

            if (self.seconds < 86400) {
                break :blk .{ "hours", self.seconds / 3600.0 };
            }

            break :blk .{ "days", self.seconds / 86400.0 };
        };

        try std.fmt.format(writer, "{d:" ++ fmt ++ "} {s}", .{ num, unit });
    }
};

const Flashing = struct {
    total: usize,
    mu: std.Thread.Mutex = .{},
    current: usize = 0,

    rates: [32]f64 = [_]f64{0} ** 32,
    rates_pos: usize = 0,
    rates_len: usize = 0,

    var percentage_buf: [8]u8 = undefined;
    var rate_buf: [16]u8 = undefined;
    var eta_buf: [32]u8 = undefined;

    inline fn parentState(self: *Flashing) *MyState {
        return @as(*MyState, @fieldParentPtr("flashing", self));
    }

    fn doflash(self: *Flashing) void {
        const rate_interval = 1000;

        // TODO: replace with real implementation
        var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
        const rand = rng.random();
        var current: usize = 0;
        var start = std.time.milliTimestamp();
        var last_progress: usize = 0;
        while (current < self.total) {
            const now = std.time.milliTimestamp();

            current += rand.intRangeAtMost(usize, 0, @min(self.total / 500, self.total - current));

            {
                self.mu.lock();
                defer self.mu.unlock();
                self.current = current;

                const dt = now - start;
                if (dt >= rate_interval) {
                    start = now;

                    const delta = current - last_progress;
                    last_progress = current;

                    self.rates[self.rates_pos] = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(dt)) * 1000.0;
                    self.rates_len = @min(self.rates_len + 1, self.rates.len);
                    self.rates_pos = (self.rates_pos + 1) % self.rates.len;
                }
            }

            self.parentState().redraw();
            std.Thread.sleep(10000000);
        }
    }

    fn onSwap(self: *Flashing, old_state: MyState) !void {
        _ = old_state;
        const thread = try std.Thread.spawn(.{}, doflash, .{self});
        thread.detach();
    }

    inline fn createLayout(state: *Flashing) void {
        clay.ui()(.{
            .layout = .{
                .sizing = .{ .width = .grow(.{}) },
                .padding = .{
                    .top = 16,
                    .bottom = 80,
                },
                .child_alignment = .center_top,
            },
        })({
            clay.text("flashing", comptime &.{ .font_size = 16, .text_color = .white });
        });

        const percent, const rate, const eta = blk: {
            state.mu.lock();
            defer state.mu.unlock();

            var rates_sum: f64 = 0;
            for (0..state.rates_len) |i| {
                rates_sum += state.rates[i];
            }

            const rate = if (state.rates_len == 0) @as(f64, 0.0) else rates_sum / @as(f64, @floatFromInt(state.rates_len));

            break :blk .{
                if (state.total == 0) 0 else @as(f64, @floatFromInt(state.current)) / @as(f64, @floatFromInt(state.total)),
                rate,
                @as(f64, @floatFromInt(state.total - state.current)) / rate,
            };
        };

        clay.ui()(.{
            .id = clay.id("ProgressBar"),
            .layout = .{
                .sizing = .{ .width = .fixed(400), .height = .fixed(48) },
            },
            .background_color = colors.loading_bar_bg,
        })({
            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .percent(@floatCast(percent)), .height = .grow(.{}) },
                },
                .background_color = colors.loading_bar_fg,
            })({});

            clay.ui()(.{
                .floating = .{
                    .attach_points = .both(.center),
                    .attach_to = .parent,
                },
            })({
                clay.text(std.fmt.bufPrint(&percentage_buf, "{d:0.2}%", .{percent * 100.0}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
            });
        });

        clay.text(std.fmt.bufPrint(&rate_buf, "{0.2}", .{HumanizeBytesPerSecond{ .bytes_per_second = rate }}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });

        if (percent == 1) {
            clay.text("done", comptime &.{ .font_size = 16, .text_color = .white });
        } else if (rate == 0 or state.total == 0) {
            clay.text("calculating eta", comptime &.{ .font_size = 16, .text_color = .white });
        } else {
            clay.text(std.fmt.bufPrint(&eta_buf, "{0.0} remaining", .{HumanizeDuration{ .seconds = eta }}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
        }
    }
};

const MyState = union(enum) {
    front_page: FrontPage,
    flashing: Flashing,

    pub const default: MyState = .{ .front_page = .{} };

    inline fn redraw(self: *const MyState) void {
        app.redraw(self);
    }

    fn setState(self: *MyState, new_state: MyState) void {
        const old_state = self.*;
        self.* = new_state;

        switch (self.*) {
            inline else => |*inner_state| if (@hasDecl(@TypeOf(inner_state.*), "onSwap")) inner_state.onSwap(old_state) catch unreachable,
        }
    }

    inline fn createLayout(self: *MyState) void {
        switch (self.*) {
            inline else => |*inner_state| inner_state.createLayout(),
        }
    }
};

pub fn createLayout(state: *MyState) clay.RenderCommandArray {
    return clay.layout()({
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
                .layout_direction = .top_to_bottom,
                .child_alignment = .center_top,
                .child_gap = 40,
            },
            .background_color = colors.bg,
        })({
            state.createLayout();
        });
    });
}

const app = frontend.App(
    MyState,
    createLayout,
);

pub fn main() !void {
    app.run();
}

test "drivelist" {
    const devices = try drivelist.listStorageDevices(std.testing.allocator);
    defer {
        for (devices) |device| {
            device.deinit(std.testing.allocator);
        }

        std.testing.allocator.free(devices);
    }

    // for (devices) |device| {
    //     std.debug.print("device: {s} {?s} {?s} {?s}\n", .{ device.device, device.device_path, device.bus_type, device.description });
    // }
}

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("svg.zig");
}
