const std = @import("std");
const clay = @import("clay");

const fonts: []const [*:0]const u8 = &.{
    "sans-serif",
};

var reinitialize_clay = false;

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

pub fn initClayContext(layout_dimensions: clay.Dimensions) !void {
    _ = try clay.Context.init(std.heap.page_allocator, layout_dimensions, error_handler);
    clay.setMeasureTextFunction(clay.renderers.cairo.measureText, @constCast(@ptrCast(fonts.ptr)));
}

pub fn setLayoutDimensions(layout_dimensions: clay.Dimensions) !void {
    if (reinitialize_clay) {
        clay.Context.getCurrent().?.deinit(std.heap.page_allocator);
        _ = try clay.Context.init(std.heap.page_allocator, layout_dimensions, error_handler);
        reinitialize_clay = false;
    } else {
        clay.setLayoutDimensions(layout_dimensions);
    }
}

pub const CommonState = struct {
    mouse_down: bool = false,
};

pub fn AppState(comptime T: type) type {
    return struct {
        common: CommonState = .{},
        data: T = .default,
    };
}

pub fn render(commands: clay.RenderCommandArray) void {
    clay.renderers.cairo.render(commands, @ptrCast(fonts.ptr));
}

pub const Cursor = enum {
    arrow,
    pointer,

    pub const default = Cursor.arrow;
};
