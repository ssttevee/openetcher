//! Colors, type and the small widgets every screen shares: buttons, links
//! and badges. Widgets are view functions rather than components, since they
//! keep no state of their own; their events are the calling component's
//! messages.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Color = fabrum.Color;

pub const window_background = Color.rgb(36, 41, 50);
pub const header_text = Color.rgb(230, 233, 238);
pub const text = Color.rgb(242, 244, 247);
pub const muted = Color.rgb(146, 154, 168);
pub const faint = Color.rgb(98, 106, 120);
pub const connector = Color.rgb(68, 75, 88);
pub const step_circle = Color.rgb(46, 52, 64);
pub const accent = Color.rgb(0, 174, 239);
pub const accent_hover = Color.rgb(38, 190, 247);
pub const accent_pressed = Color.rgb(0, 148, 206);
pub const disabled = Color.rgb(60, 66, 78);
pub const disabled_text = Color.rgb(120, 128, 142);
pub const track = Color.rgb(56, 62, 74);
pub const verifying = Color.rgb(26, 193, 101);
pub const success = Color.rgb(26, 193, 101);
pub const warning = Color.rgb(255, 176, 32);
pub const danger = Color.rgb(255, 92, 92);
pub const danger_hover = Color.rgb(255, 118, 118);
pub const danger_pressed = Color.rgb(226, 70, 70);

/// The light card of dialogs.
pub const card = Color.rgb(255, 255, 255);
pub const card_text = Color.rgb(37, 42, 51);
pub const card_muted = Color.rgb(112, 120, 134);
pub const card_line = Color.rgb(229, 232, 237);
pub const card_selected = Color.rgb(229, 245, 253);
pub const card_hover = Color.rgb(244, 246, 249);
pub const backdrop = Color.rgba(10, 12, 16, 170);

pub const Text = enum { title, heading, label, body, small, caption };

/// A text style for one of the type sizes.
pub fn font(kind: Text, color: Color) layout.text.Style {
    const size: f32, const weight: layout.text.Weight = switch (kind) {
        .title => .{ 26, .bold },
        .heading => .{ 19, .semibold },
        .label => .{ 15, .semibold },
        .body => .{ 14, .regular },
        .small => .{ 13, .regular },
        .caption => .{ 11, .semibold },
    };
    return .{ .font_size = size, .font_weight = weight, .color = color, .wrap_mode = .words };
}

pub const ButtonKind = enum { primary, danger, secondary };

pub fn ButtonOptions(comptime Msg: type) type {
    return struct {
        /// Null disables the button.
        on_click: ?Msg,
        kind: ButtonKind = .primary,
        /// Zero fits the label.
        width: f32 = 0,
        height: f32 = 40,
    };
}

/// A pill button that lightens on hover and darkens while pressed.
pub fn button(comptime C: type, ui: *app.Scope(C), key: anytype, label: []const u8, options: ButtonOptions(C.Msg)) !void {
    const enabled = options.on_click != null;
    const hovered = enabled and ui.hovered(key);
    const pressed = enabled and ui.pressed(key);

    const background: Color, const foreground: Color, const outline: Color = if (!enabled)
        .{ disabled, disabled_text, .transparent }
    else switch (options.kind) {
        .primary => .{ if (pressed) accent_pressed else if (hovered) accent_hover else accent, .white, .transparent },
        .danger => .{ if (pressed) danger_pressed else if (hovered) danger_hover else danger, .white, .transparent },
        .secondary => .{ if (pressed) card_line else if (hovered) card_hover else card, card_text, card_line },
    };

    try ui.open(key, .{
        .layout = .{
            .sizing = .{
                .width = if (options.width > 0) .fixed(options.width) else .fit(.{}),
                .height = .fixed(options.height),
            },
            .padding = .x(22),
            .child_alignment = .center,
        },
        .background_color = background,
        .corner_radius = .uniform(options.height / 2),
        .border = .{ .color = outline, .widths = if (outline.isTransparent()) .{} else .outside(1) },
        .on_click = options.on_click,
    });
    defer ui.close();
    var style = font(.label, foreground);
    style.wrap_mode = .none;
    try ui.text(label, style);
}

/// Clickable text, underlined by color only: brighter while hovered.
pub fn link(comptime C: type, ui: *app.Scope(C), key: anytype, label: []const u8, on_click: C.Msg, color: Color) !void {
    try ui.open(key, .{ .layout = .{ .padding = .xy(2, 1) }, .on_click = on_click });
    defer ui.close();
    const shown = if (ui.pressed(key)) color.withAlpha(160) else if (ui.hovered(key)) lighten(color) else color;
    var style = font(.small, shown);
    style.font_weight = .medium;
    style.wrap_mode = .none;
    try ui.text(label, style);
}

/// A small rounded label, such as a drive warning.
pub fn badge(comptime C: type, ui: *app.Scope(C), label: []const u8, color: Color) !void {
    try ui.open(null, .{
        .layout = .{ .padding = .xy(7, 2) },
        .background_color = color.withAlpha(40),
        .corner_radius = .uniform(9),
    });
    defer ui.close();
    var style = font(.caption, color);
    style.wrap_mode = .none;
    try ui.text(label, style);
}

/// A square box of `size` showing `icon`.
pub fn icon(comptime C: type, ui: *app.Scope(C), content: *layout.Content, size: f32) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .fixed(size), .child_alignment = .center } });
    defer ui.close();
    ui.content(content);
}

fn lighten(color: Color) Color {
    return .rgba(
        color.r +| (255 - color.r) / 3,
        color.g +| (255 - color.g) / 3,
        color.b +| (255 - color.b) / 3,
        color.a,
    );
}
