//! Asks before anything is written to a drive, with a stronger warning for
//! system drives.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");

const ConfirmDialog = @This();

pub const State = struct {};

pub const Msg = union(enum) { confirm, cancel };

pub const Props = struct {
    drive: *const model.Drive,
    image_name: []const u8,
    icons: *const model.Icons,
    on_confirm: app.Handler(void),
    on_cancel: app.Handler(void),
};

pub fn update(_: *State, msg: Msg, ctx: *app.Update(ConfirmDialog)) void {
    switch (msg) {
        .confirm => ctx.emit(ctx.props.on_confirm, {}),
        .cancel => ctx.emit(ctx.props.on_cancel, {}),
    }
}

pub fn view(ui: *app.Scope(ConfirmDialog), _: *const State, props: Props) !void {
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

    const warning_color = if (drive.system) theme.danger else theme.warning;
    try theme.icon(ConfirmDialog, ui, try props.icons.content(ui.arena(), .warning, warning_color), 40);

    var name_buffer: [64]u8 = undefined;
    const name = format.middle(&name_buffer, drive.name, 32);
    var title_style = theme.font(.heading, theme.card_text);
    title_style.alignment = .center;
    try ui.text(try ui.fmt("Erase {s}?", .{name}), title_style);

    var size_buffer: [32]u8 = undefined;
    var image_buffer: [64]u8 = undefined;
    var body = theme.font(.body, theme.card_muted);
    body.alignment = .center;
    try paragraph(ui, try ui.fmt("Everything on {s} ({s}, {s}) will be replaced with {s}. This can't be undone.", .{
        name,
        format.bytes(&size_buffer, drive.size),
        drive.location,
        format.middle(&image_buffer, props.image_name, 40),
    }), body);

    if (drive.system) {
        var alarm = theme.font(.body, theme.danger);
        alarm.alignment = .center;
        alarm.font_weight = .semibold;
        try paragraph(ui, "This is a system drive. Writing to it can leave this Mac unable to start.", alarm);
    }

    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 8, 0), .child_gap = 12 } });
    defer ui.close();
    try theme.button(ConfirmDialog, ui, "cancel", "Cancel", .{ .on_click = .cancel, .kind = .secondary, .height = 38 });
    try theme.button(ConfirmDialog, ui, "confirm", if (drive.system) "Erase system drive" else "Yes, flash it", .{
        .on_click = .confirm,
        .kind = if (drive.system) .danger else .primary,
        .height = 38,
    });
}

/// Text wrapped to the card's width.
fn paragraph(ui: *app.Scope(ConfirmDialog), text: []const u8, style: fabrum.layout.text.Style) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(388) }, .child_alignment = .top_center } });
    defer ui.close();
    try ui.text(text, style);
}
