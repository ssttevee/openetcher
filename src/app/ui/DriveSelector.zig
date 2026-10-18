//! The "Select target" dialog: a list of drives over the main screen.
//!
//! The list itself belongs to the app, which lists drives when the dialog
//! opens. The dialog keeps what only it cares about: the row the user has
//! picked but not confirmed yet, and whether system drives are shown.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const Drive = model.Drive;

const DriveSelector = @This();

pub const State = struct {
    /// Key of the picked row, from `key`. Null means the app's current
    /// target, if any.
    chosen: ?u64 = null,
    /// Whether system drives are listed.
    show_hidden: bool = false,
};

pub const Msg = union(enum) {
    choose: u64,
    toggle_hidden,
    refresh,
    cancel,
    select,
};

pub const Props = struct {
    drives: []const Drive = &.{},
    loading: bool = false,
    failure: ?anyerror = null,
    /// The image's size, to mark drives too small for it.
    image_size: ?u64 = null,
    /// Path of the current target, picked when the dialog opens.
    current: ?[]const u8 = null,
    on_cancel: app.Handler(void),
    /// The index in `drives` of the confirmed choice.
    on_select: app.Handler(usize),
    on_refresh: app.Handler(void),
};

pub fn update(state: *State, msg: Msg, ctx: *app.Update(DriveSelector)) void {
    switch (msg) {
        .choose => |chosen| state.chosen = chosen,
        .toggle_hidden => state.show_hidden = !state.show_hidden,
        .refresh => ctx.emit(ctx.props.on_refresh, {}),
        .cancel => ctx.emit(ctx.props.on_cancel, {}),
        .select => if (selectedIndex(state, ctx.props.*)) |index| ctx.emit(ctx.props.on_select, index),
    }
}

/// Identifies a drive across relistings, where its index may change.
pub fn key(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

fn selectable(drive: Drive, props: Props) bool {
    return if (props.image_size) |size| drive.size >= size else true;
}

fn visible(state: *const State, drive: Drive) bool {
    return state.show_hidden or !drive.system;
}

/// The index of the picked drive, if it is listed, shown and big enough.
fn selectedIndex(state: *const State, props: Props) ?usize {
    const chosen = state.chosen orelse key(props.current orelse return null);
    for (props.drives, 0..) |drive, index| {
        if (key(drive.path) == chosen) {
            return if (visible(state, drive) and selectable(drive, props)) index else null;
        }
    }
    return null;
}

pub fn view(ui: *app.Scope(DriveSelector), state: *const State, props: Props) !void {
    // the backdrop covers the window and swallows clicks meant for the screen below
    try ui.open("backdrop", .{
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
        .background_color = theme.backdrop,
        .floating = .{ .mode = .root },
    });
    defer ui.close();

    try ui.open("card", .{
        .layout = .{ .sizing = .{ .width = .fixed(620), .height = .fit(.{}) }, .axis = .y, .padding = .all(24), .child_gap = 16 },
        .background_color = theme.card,
        .corner_radius = .uniform(12),
    });
    defer ui.close();

    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_alignment = .center_left, .child_gap = 10 } });
        defer ui.close();
        try ui.text("Select target", theme.font(.heading, theme.card_text));
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
        ui.close();
        if (!props.loading) try theme.link(DriveSelector, ui, "refresh", "Refresh", .refresh, theme.accent);
    }

    try table(ui, state, props);

    var hidden: usize = 0;
    for (props.drives) |drive| {
        if (drive.system) hidden += 1;
    }

    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_alignment = .center_left, .child_gap = 12 } });
    defer ui.close();
    if (hidden > 0) {
        const label = if (state.show_hidden)
            try ui.fmt("Hide {d} system {s}", .{ hidden, if (hidden == 1) "drive" else "drives" })
        else
            try ui.fmt("Show {d} hidden", .{hidden});
        try theme.link(DriveSelector, ui, "hidden", label, .toggle_hidden, theme.card_muted);
    }
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
    ui.close();
    try theme.button(DriveSelector, ui, "cancel", "Cancel", .{ .on_click = .cancel, .kind = .secondary, .height = 36 });
    try theme.button(DriveSelector, ui, "select", "Select", .{
        .on_click = if (selectedIndex(state, props) != null) .select else null,
        .height = 36,
    });
}

const size_width = 90;
const location_width = 170;

fn table(ui: *app.Scope(DriveSelector), state: *const State, props: Props) !void {
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fit(.{ .min = 140, .max = 300 }) }, .axis = .y },
        .clip = .{ .vertical = true },
    });
    defer ui.close();

    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(40, 12, 0, 8), .child_gap = 12 } });
        defer ui.close();
        try column(ui, .grow(.{}), "NAME", theme.font(.caption, theme.card_muted));
        try column(ui, .fixed(size_width), "SIZE", theme.font(.caption, theme.card_muted));
        try column(ui, .fixed(location_width), "LOCATION", theme.font(.caption, theme.card_muted));
    }

    if (props.loading) return message(ui, "Looking for drives\u{2026}");
    if (props.failure) |err| return message(ui, model.describeError(err));

    const selected = selectedIndex(state, props);
    var shown: usize = 0;
    for (props.drives, 0..) |drive, index| {
        if (!visible(state, drive)) continue;
        shown += 1;
        try row(ui, drive, index, selected == index, selectable(drive, props));
    }
    if (shown == 0) try message(ui, "Connect a drive to write the image to.");
}

fn row(ui: *app.Scope(DriveSelector), drive: Drive, index: usize, selected: bool, enabled: bool) !void {
    // rows are keyed by index; every other key here is a string
    const row_key = index;
    const hovered = enabled and ui.hovered(row_key);
    try ui.open(row_key, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .xy(12, 10), .child_gap = 12, .child_alignment = .center_left },
        .background_color = if (selected) theme.card_selected else if (hovered) theme.card_hover else .transparent,
        .corner_radius = .uniform(8),
        .on_click = if (enabled) .{ .choose = key(drive.path) } else null,
    });
    defer ui.close();

    // a radio mark
    try ui.open(null, .{
        .layout = .{ .sizing = .fixed(16), .child_alignment = .center },
        .corner_radius = .uniform(8),
        .border = .{ .color = if (selected) theme.accent else theme.card_line, .widths = .outside(if (selected) 5 else 1.5) },
    });
    ui.close();

    const text_color = if (enabled) theme.card_text else theme.card_muted;
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .child_gap = 3 } });
        defer ui.close();
        var name_buffer: [64]u8 = undefined;
        var style = theme.font(.body, text_color);
        style.font_weight = .medium;
        style.wrap_mode = .none;
        try ui.text(try ui.arena().dupe(u8, format.middle(&name_buffer, drive.name, 36)), style);

        try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
        defer ui.close();
        if (drive.system) try theme.badge(DriveSelector, ui, "SYSTEM DRIVE", theme.danger);
        if (!enabled) try theme.badge(DriveSelector, ui, "TOO SMALL", theme.card_muted);
        if (drive.file) try theme.badge(DriveSelector, ui, "FILE", theme.accent);
        if (drive.removable and !drive.file) try theme.badge(DriveSelector, ui, "REMOVABLE", theme.success);
    }

    var size_buffer: [32]u8 = undefined;
    try column(ui, .fixed(size_width), try ui.arena().dupe(u8, format.bytes(&size_buffer, drive.size)), theme.font(.body, text_color));
    var location_buffer: [64]u8 = undefined;
    try column(ui, .fixed(location_width), try ui.arena().dupe(u8, format.middle(&location_buffer, drive.location, 26)), theme.font(.small, theme.card_muted));
}

fn column(ui: *app.Scope(DriveSelector), width: fabrum.layout.Sizing.Dimension, label: []const u8, style: fabrum.layout.text.Style) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = width } } });
    defer ui.close();
    var no_wrap = style;
    no_wrap.wrap_mode = .none;
    try ui.text(label, no_wrap);
}

fn message(ui: *app.Scope(DriveSelector), text: []const u8) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(90) }, .child_alignment = .center } });
    defer ui.close();
    try ui.text(text, theme.font(.body, theme.card_muted));
}
