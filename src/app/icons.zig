//! The interface's icons as Quartz pictures.
//!
//! The SVGs in `icons/` are from Bootstrap Icons (https://icons.getbootstrap.com),
//! MIT licensed; see `icons/LICENSE`. They are path-only, as the renderer's
//! SVG support requires, and filled with whatever color a view asks for.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const Picture = fabrum.render.Quartz.content.Picture;

const model = @import("ui.zig").model;

const Icons = @This();

pictures: std.EnumArray(model.Icon, Picture),

const sources = std.EnumArray(model.Icon, []const u8).init(.{
    .image = @embedFile("icons/file-earmark-plus-fill.svg"),
    .drive = @embedFile("icons/hdd-fill.svg"),
    .flash = @embedFile("icons/lightning-charge-fill.svg"),
    .done = @embedFile("icons/check-circle-fill.svg"),
    .failed = @embedFile("icons/x-circle-fill.svg"),
    .warning = @embedFile("icons/exclamation-triangle-fill.svg"),
});

pub fn init(gpa: Allocator) !Icons {
    var self: Icons = .{ .pictures = undefined };
    var made: usize = 0;
    errdefer for (std.enums.values(model.Icon)[0..made]) |icon| self.pictures.getPtr(icon).deinit();
    for (std.enums.values(model.Icon)) |icon| {
        self.pictures.set(icon, try Picture.fromSVG(gpa, sources.get(icon)));
        made += 1;
    }
    return self;
}

pub fn deinit(self: *Icons) void {
    for (std.enums.values(model.Icon)) |icon| self.pictures.getPtr(icon).deinit();
    self.* = undefined;
}

pub fn interface(self: *Icons) model.Icons {
    return .{ .ctx = self, .make = make };
}

/// A copy of the picture in the frame arena, filled with `color`. The copy
/// shares the path, which the original owns.
fn make(ctx: *anyopaque, arena: Allocator, icon: model.Icon, color: fabrum.Color) Allocator.Error!*fabrum.layout.Content {
    const self: *Icons = @ptrCast(@alignCast(ctx));
    const picture = try arena.create(Picture);
    picture.* = self.pictures.get(icon);
    picture.style.color = color;
    return &picture.content;
}

test "every icon parses" {
    var icons: Icons = try .init(std.testing.allocator);
    defer icons.deinit();
    for (std.enums.values(model.Icon)) |icon| {
        try std.testing.expect(icons.pictures.get(icon).source.vector.viewbox.w == 16);
    }
}
