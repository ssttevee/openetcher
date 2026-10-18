//! Asks before anything is written to a drive, with a stronger warning for
//! system drives.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");

pub const Props = struct {
    drive: *const model.Drive,
    image_name: []const u8,
    on_confirm: app.Action,
    on_cancel: app.Action,
};

pub fn view(ui: *app.Ui, props: Props) !void {
    const drive = props.drive;

    try ui.open("backdrop", .{
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
        .background_color = theme.backdrop,
        .floating = .{ .mode = .root },
    });
    defer ui.close();

    try ui.open("card", .{
        .layout = .{ .sizing = .{ .width = .fixed(440) }, .axis = .y, .padding = .all(26), .child_gap = 14, .child_alignment = .top_center },
        .background_color = theme.card,
        .corner_radius = .uniform(12),
    });
    defer ui.close();

    try theme.icon(ui, .warning, if (drive.system) theme.danger else theme.warning, 40);

    var name_buffer: [64]u8 = undefined;
    const name = format.middle(&name_buffer, drive.name, 32);
    try ui.print(theme.font(.heading, theme.card_text).with(.{ .alignment = .center }), "Erase {s}?", .{name});

    var image_buffer: [64]u8 = undefined;
    const body = theme.font(.body, theme.card_muted).with(.{ .alignment = .center });
    try paragraph(ui, body, "Everything on {s} ({f}, {s}) will be replaced with {s}. This can't be undone.", .{
        name,
        format.bytes(drive.size),
        drive.location,
        format.middle(&image_buffer, props.image_name, 40),
    });

    if (drive.system) {
        const alarm = theme.font(.body, theme.danger).with(.{ .alignment = .center, .font_weight = .semibold });
        try paragraph(ui, alarm, "This is a system drive. Writing to it can leave this Mac unable to start.", .{});
    }

    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 8, 0), .child_gap = 12 } });
    defer ui.close();
    try theme.button(ui, "cancel", "Cancel", .{ .on_click = props.on_cancel, .kind = .secondary, .height = 38 });
    try theme.button(ui, "confirm", if (drive.system) "Erase system drive" else "Yes, flash it", .{
        .on_click = props.on_confirm,
        .kind = if (drive.system) .danger else .primary,
        .height = 38,
    });
}

/// Text wrapped to the card's width, formatted as with `ui.print`.
fn paragraph(ui: *app.Ui, style: fabrum.layout.text.Style, comptime fmt: []const u8, args: anytype) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(388) }, .child_alignment = .top_center } });
    defer ui.close();
    try ui.print(style, fmt, args);
}
