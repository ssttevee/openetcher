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
};

const FrontPage = struct {
    current_step: u8 = 0,
    highlighted_button: u8 = 0,
    hovering_button: bool = false,
    prev_hovering: bool = false,

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
            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .fixed(200) },
                    .layout_direction = .top_to_bottom,
                },
            })({
                state.buttonLayout(0, 0, "ImageFromFileButton", "Flash from file");
                state.buttonLayout(0, 1, "ImageFromURLButton", "Flash from URL");
                state.buttonLayout(0, 2, "ImageFromDiskButton", "Clone a disk");
            });

            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .fixed(200) },
                    .layout_direction = .top_to_bottom,
                },
            })({
                state.buttonLayout(1, 0, "SelectTargetButton", "Select Target");
            });

            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .fixed(200) },
                    .layout_direction = .top_to_bottom,
                },
            })({
                state.buttonLayout(1, 0, "FlashButton", "Flash!");
            });
        });
    }

    fn onHoverButtonStack(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
        _ = element_id;

        const state: *FrontPage = @alignCast(@ptrCast(user_data));

        state.highlighted_button, state.hovering_button = blk: {
            if (clay.getElementData(clay.id("ImageFromFileButton"))) |element_data| {
                if (element_data.bounding_box.contains(pointer_data.position)) {
                    break :blk .{ 0, true };
                }
            }

            if (clay.getElementData(clay.id("ImageFromURLButton"))) |element_data| {
                if (element_data.bounding_box.contains(pointer_data.position)) {
                    break :blk .{ 1, true };
                }
            }

            if (clay.getElementData(clay.id("ImageFromDiskButton"))) |element_data| {
                if (element_data.bounding_box.contains(pointer_data.position)) {
                    break :blk .{ 2, true };
                }
            }

            break :blk .{ 0, false };
        };

        if (state.prev_hovering != state.hovering_button) {
            state.prev_hovering = state.hovering_button;

            frontend.platform.setCursor(if (state.hovering_button) .pointer else .arrow);
        }

        switch (pointer_data.state) {
            .released_this_frame => {
                if (state.hovering_button) {
                    // TODO: handle button click
                    std.debug.print("button {d} onmouseup\n", .{state.highlighted_button});
                }
            },
            .pressed_this_frame => {
                if (state.hovering_button) {
                    // TODO: handle button click
                    std.debug.print("button {d} onmousedown\n", .{state.highlighted_button});
                }
            },
            else => {},
        }

        // std.debug.print("pointer_data.state {any}\n", .{pointer_data.state});
    }
};

const MyState = union(enum) {
    front_page: FrontPage,

    pub const default: MyState = .{ .front_page = .{} };

    inline fn createLayout(state: *MyState) void {
        switch (state.*) {
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
