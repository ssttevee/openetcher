const std = @import("std");
const clay = @import("clay");

const frontend = @import("frontend.zig");

const MyState = struct {
    pub const default: MyState = .{};
};

pub fn createLayout(state: *const frontend.AppState(MyState)) clay.RenderCommandArray {
    return clay.layout()({
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
                .child_alignment = .center,
            },
            .background_color = .rgb(76, 80, 91),
        })({
            clay.ui()(.{
                .id = clay.id("box"),
                .layout = .{
                    .sizing = .fixed(40),
                },
                .background_color = if (state.common.mouse_down) .rgb(0, 255, 0) else if (clay.isHovered()) .rgb(255, 0, 0) else clay.Color.white,
            })({});
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

test {
    std.testing.refAllDeclsRecursive(@This());
}
