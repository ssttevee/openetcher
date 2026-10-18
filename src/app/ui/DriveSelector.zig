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
    on_cancel: app.Action,
    /// The index in `drives` of the confirmed choice.
    on_select: app.Handler(usize),
    on_refresh: app.Action,
};

pub fn update(state: *State, msg: Msg, ctx: *app.Update(DriveSelector)) void {
    switch (msg) {
        .choose => |chosen| state.chosen = chosen,
        .toggle_hidden => state.show_hidden = !state.show_hidden,
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

pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
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
        ui.spacer();
        if (!props.loading) try theme.link(ui, "refresh", "Refresh", props.on_refresh, theme.accent);
    }

    try table(ui, state, props);

    const on = ui.messages(DriveSelector);
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
        try theme.link(ui, "hidden", label, on.bind(.toggle_hidden), theme.card_muted);
    }
    ui.spacer();
    try theme.button(ui, "cancel", "Cancel", .{ .on_click = props.on_cancel, .kind = .secondary, .height = 36 });
    try theme.button(ui, "select", "Select", .{
        .on_click = if (selectedIndex(state, props) != null) on.bind(.select) else null,
        .height = 36,
    });
}

const size_width = 90;
const location_width = 170;

fn table(ui: *app.Ui, state: *const State, props: Props) !void {
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fit(.{ .min = 140, .max = 300 }) }, .axis = .y },
        .clip = .{ .vertical = true },
    });
    defer ui.close();

    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(40, 12, 0, 8), .child_gap = 12 } });
        defer ui.close();
        const heading = theme.font(.caption, theme.card_muted);
        try column(ui, .grow(.{}), "NAME", heading);
        try column(ui, .fixed(size_width), "SIZE", heading);
        try column(ui, .fixed(location_width), "LOCATION", heading);
    }

    if (props.loading) return message(ui, "Looking for drives\u{2026}");
    if (props.failure) |err| return message(ui, model.describeError(err));

    const selected = selectedIndex(state, props);
    var shown: usize = 0;
    for (props.drives, 0..) |*drive, index| {
        if (!visible(state, drive.*)) continue;
        shown += 1;
        // keyed by path, which stays with the drive when a relisting reorders it
        try ui.child(Row, drive.path, .{ .drive = drive, .selected = selected == index, .enabled = selectable(drive.*, props) });
    }
    if (shown == 0) try message(ui, "Connect a drive to write the image to.");
}

/// One drive in the list. Clicking it picks it in the `DriveSelector`
/// around it.
const Row = struct {
    pub const Props = struct {
        drive: *const Drive,
        selected: bool,
        /// Whether the drive can be picked: not if it is too small.
        enabled: bool,
    };

    pub fn view(ui: *app.Ui, props: Row.Props) !void {
        const drive = props.drive;
        const hovered = props.enabled and ui.hovered("row");
        try ui.open("row", .{
            .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .xy(12, 10), .child_gap = 12, .child_alignment = .center_left },
            .background_color = if (props.selected) theme.card_selected else if (hovered) theme.card_hover else .transparent,
            .corner_radius = .uniform(8),
            .on_click = if (props.enabled) ui.messages(DriveSelector).bind(.{ .choose = key(drive.path) }) else null,
        });
        defer ui.close();

        // a radio mark
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(16), .child_alignment = .center },
            .corner_radius = .uniform(8),
            .border = .{ .color = if (props.selected) theme.accent else theme.card_line, .widths = .outside(if (props.selected) 5 else 1.5) },
        });
        ui.close();

        const text_color = if (props.enabled) theme.card_text else theme.card_muted;
        {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .child_gap = 3 } });
            defer ui.close();
            try ui.text(drive.name, theme.font(.body, text_color).with(.{ .font_weight = .medium, .wrap_mode = .none, .overflow = .ellipsis_middle }));

            try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
            defer ui.close();
            if (drive.system) try theme.badge(ui, "SYSTEM DRIVE", theme.danger);
            if (!props.enabled) try theme.badge(ui, "TOO SMALL", theme.card_muted);
            if (drive.file) try theme.badge(ui, "FILE", theme.accent);
            if (drive.removable and !drive.file) try theme.badge(ui, "REMOVABLE", theme.success);
        }

        try column(ui, .fixed(size_width), try ui.fmt("{f}", .{format.bytes(drive.size)}), theme.font(.body, text_color));
        try column(ui, .fixed(location_width), drive.location, theme.font(.small, theme.card_muted).with(.{ .overflow = .ellipsis_middle }));
    }
};

/// A table cell of `width` holding one line of text.
fn column(ui: *app.Ui, width: fabrum.layout.Sizing.Dimension, label: []const u8, style: fabrum.layout.text.Style) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = width } } });
    defer ui.close();
    try ui.text(label, style.with(.{ .wrap_mode = .none }));
}

fn message(ui: *app.Ui, text: []const u8) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(90) }, .child_alignment = .center } });
    defer ui.close();
    try ui.text(text, theme.font(.body, theme.card_muted));
}
