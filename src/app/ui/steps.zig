//! The three steps across the main screen: choose an image, choose a target,
//! flash. Each is a circular icon over a pill button, with what was chosen
//! below it.
//!
//! The steps are stateless: their buttons fire whatever actions the app
//! passes in.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Color = fabrum.Color;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");

pub const width = 190;
pub const height = 236;
pub const icon_size = 72;
pub const connector_width = 64;
const button_width = 170;
const button_height = 44;

/// Opens a step's column and draws its icon in a circle, ringed once the
/// step is done; close it with `ui.close()`.
fn open(ui: *app.Ui, icon: model.Icon, color: Color, done: bool) !void {
    // a fixed height keeps the row still as details come and go
    try ui.open(null, .{
        .layout = .{ .sizing = .fixedXY(width, height), .axis = .y, .child_alignment = .top_center, .child_gap = 6 },
    });
    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 0, 20) } });
    try ui.open(null, .{
        .layout = .{ .sizing = .fixed(icon_size), .child_alignment = .center },
        .background_color = theme.step_circle,
        .corner_radius = .uniform(icon_size / 2),
        .border = .{ .color = if (done) theme.accent else .transparent, .widths = .outside(2) },
    });
    try theme.icon(ui, icon, color, 34);
    ui.close();
    ui.close();
}

/// What a step has chosen, in place of its button, cut in the middle to
/// fit.
fn chosen(ui: *app.Ui, name: []const u8) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .height = .fixed(button_height) }, .child_alignment = .center } });
    defer ui.close();
    try ui.text(name, theme.font(.label, theme.text).with(.{ .wrap_mode = .none, .overflow = .ellipsis_middle }));
}

/// A wrapped, centered line under a step's button, formatted as with
/// `ui.print`.
fn caption(ui: *app.Ui, style: layout.text.Style, comptime fmt: []const u8, args: anytype) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(width) }, .child_alignment = .top_center } });
    defer ui.close();
    try ui.print(style.with(.{ .alignment = .center }), fmt, args);
}

/// The thin line joining two steps, level with their icons' centers.
pub fn connector(ui: *app.Ui, done: bool) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(connector_width) }, .padding = .init(0, 0, icon_size / 2 - 1, 0) } });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .fixedXY(connector_width, 2) },
        .background_color = if (done) theme.accent.withAlpha(150) else theme.connector,
        .corner_radius = .uniform(1),
    });
    ui.close();
}

/// Step 1: the image.
pub const ImageStep = struct {
    pub const Props = struct {
        image: ?*const model.Image,
        /// Whether the image can be changed: not while flashing.
        locked: bool = false,
        on_pick: app.Action,
        on_remove: app.Action,
    };

    pub fn view(ui: *app.Ui, props: Props) !void {
        try open(ui, .image, if (props.locked) theme.faint else theme.text, if (props.image) |image| image.status == .ready else false);
        defer ui.close();

        const image = props.image orelse {
            return theme.button(ui, "pick", "Flash from file", .{ .on_click = props.on_pick, .width = button_width, .height = button_height });
        };

        try chosen(ui, image.name());
        const details_style = theme.font(.small, theme.muted);
        switch (image.status) {
            .loading => |loading| if (loading.total > 0)
                try caption(ui, details_style, "Decompressing\u{2026} {d}%", .{@min(100, loading.decoded * 100 / loading.total)})
            else
                try caption(ui, details_style, "Reading image\u{2026}", .{}),
            .ready => |details| if (details.compression) |compression|
                try caption(ui, details_style, "{f} \u{00b7} {s}", .{ format.bytes(details.size), compression })
            else
                try caption(ui, details_style, "{f}", .{format.bytes(details.size)}),
            .failed => |err| try caption(ui, theme.font(.small, theme.danger), "{s}", .{model.describeError(err)}),
        }
        if (!props.locked) try theme.link(ui, "remove", "Remove", props.on_remove, theme.accent);
    }
};

/// Step 2: the drive to write to.
pub const TargetStep = struct {
    pub const Props = struct {
        target: ?*const model.Drive,
        /// Whether an image has been chosen, which comes first.
        enabled: bool,
        locked: bool = false,
        image_size: ?u64 = null,
        on_open: app.Action,
    };

    pub fn view(ui: *app.Ui, props: Props) !void {
        try open(ui, .drive, if (props.enabled and !props.locked) theme.text else theme.faint, props.target != null);
        defer ui.close();

        const drive = props.target orelse {
            return theme.button(ui, "open", "Select target", .{
                .on_click = if (props.enabled) props.on_open else null,
                .width = button_width,
                .height = button_height,
            });
        };

        try chosen(ui, drive.name);
        try caption(ui, theme.font(.small, theme.muted), "{f}", .{format.bytes(drive.size)});
        if (props.image_size) |size| {
            if (drive.size < size) try caption(ui, theme.font(.small, theme.danger), "Too small for this image", .{});
        }
        if (drive.system) try caption(ui, theme.font(.small, theme.danger), "System drive", .{});
        if (!props.locked) try theme.link(ui, "change", "Change", props.on_open, theme.accent);
    }
};

/// Step 3: the flash button, which becomes a progress bar while flashing.
pub const FlashStep = struct {
    pub const Props = struct {
        /// Whether everything is chosen and fits.
        ready: bool,
        running: ?*const model.Running = null,
        on_flash: app.Action,
        on_cancel: app.Action,
    };

    pub fn view(ui: *app.Ui, props: Props) !void {
        const active = props.ready or props.running != null;
        try open(ui, .flash, if (active) theme.text else theme.faint, props.running != null);
        defer ui.close();

        const running = props.running orelse {
            return theme.button(ui, "flash", "Flash!", .{
                .on_click = if (props.ready) props.on_flash else null,
                .width = button_width,
                .height = button_height,
            });
        };

        try progressBar(ui, running);

        const details_style = theme.font(.small, theme.muted);
        if (running.canceling) {
            return caption(ui, details_style, "Canceling\u{2026}", .{});
        }
        if (running.speed > 0) {
            if (running.secondsLeft()) |left| {
                try caption(ui, details_style, "{f} \u{00b7} ETA {f}", .{ format.speed(running.speed), format.duration(left) });
            } else {
                try caption(ui, details_style, "{f}", .{format.speed(running.speed)});
            }
        } else {
            try caption(ui, details_style, " ", .{});
        }
        try theme.link(ui, "cancel", "Cancel", props.on_cancel, theme.danger);
    }

    fn progressBar(ui: *app.Ui, running: *const model.Running) !void {
        const color = if (running.phase == .verifying) theme.verifying else theme.accent;
        const fraction = running.fraction();

        try ui.open("bar", .{
            .layout = .{ .sizing = .fixedXY(button_width, button_height) },
            .background_color = theme.track,
            .corner_radius = .uniform(button_height / 2),
            .clip = .{ .horizontal = true },
        });
        defer ui.close();

        const filled = (fraction orelse 0) * button_width;
        if (filled > 0) {
            try ui.open(null, .{
                .layout = .{ .sizing = .fixedXY(@max(filled, button_height), button_height) },
                .background_color = color,
                .corner_radius = .uniform(button_height / 2),
            });
            ui.close();
        }

        // the label floats over the fill
        try ui.open(null, .{
            .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
            .floating = .{ .mode = .parent },
        });
        defer ui.close();
        const verb = switch (running.phase) {
            .starting => "Starting",
            .decoding => "Decompressing",
            .flashing => "Flashing",
            .verifying => "Validating",
        };
        const style = theme.font(.label, .white).with(.{ .wrap_mode = .none });
        if (fraction) |value| {
            try ui.print(style, "{s}\u{2026} {d}%", .{ verb, @as(u32, @intFromFloat(@floor(value * 100))) });
        } else {
            try ui.print(style, "{s}\u{2026}", .{verb});
        }
    }
};
