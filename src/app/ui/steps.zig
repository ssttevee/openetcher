//! The three steps across the main screen: choose an image, choose a target,
//! flash. Each is a circular icon over a pill button, with what was chosen
//! below it.
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
fn open(comptime C: type, ui: *app.Scope(C), icons: *const model.Icons, icon: model.Icon, color: Color, done: bool) !void {
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
    try theme.icon(C, ui, try icons.content(ui.arena(), icon, color), 34);
    ui.close();
    ui.close();
}

/// A wrapped, centered line under a step's button.
fn caption(comptime C: type, ui: *app.Scope(C), text: []const u8, style: layout.text.Style) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(width) }, .child_alignment = .top_center } });
    defer ui.close();
    var centered = style;
    centered.alignment = .center;
    try ui.text(text, centered);
}

/// The thin line joining two steps, level with their icons' centers.
pub fn connector(comptime C: type, ui: *app.Scope(C), done: bool) !void {
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
    pub const State = struct {};
    pub const Msg = union(enum) { pick, remove };
    pub const Props = struct {
        image: ?*const model.Image,
        /// Whether the image can be changed: not while flashing.
        locked: bool = false,
        icons: *const model.Icons,
        on_pick: app.Handler(void),
        on_remove: app.Handler(void),
    };

    pub fn update(_: *State, msg: Msg, ctx: *app.Update(ImageStep)) void {
        switch (msg) {
            .pick => ctx.emit(ctx.props.on_pick, {}),
            .remove => ctx.emit(ctx.props.on_remove, {}),
        }
    }

    pub fn view(ui: *app.Scope(ImageStep), _: *const State, props: Props) !void {
        try open(ImageStep, ui, props.icons, .image, if (props.locked) theme.faint else theme.text, if (props.image) |image| image.status == .ready else false);
        defer ui.close();

        const image = props.image orelse {
            try theme.button(ImageStep, ui, "pick", "Flash from file", .{ .on_click = .pick, .width = button_width, .height = button_height });
            return;
        };

        var name_buffer: [64]u8 = undefined;
        var name_style = theme.font(.label, theme.text);
        name_style.wrap_mode = .none;
        try ui.open(null, .{ .layout = .{ .sizing = .{ .height = .fixed(button_height) }, .child_alignment = .center } });
        try ui.text(try ui.arena().dupe(u8, format.middle(&name_buffer, image.name(), 24)), name_style);
        ui.close();

        switch (image.status) {
            .loading => |loading| try caption(ImageStep, ui, if (loading.total > 0)
                try ui.fmt("Decompressing\u{2026} {d}%", .{@min(100, loading.decoded * 100 / loading.total)})
            else
                "Reading image\u{2026}", theme.font(.small, theme.muted)),
            .ready => |details| {
                var size_buffer: [32]u8 = undefined;
                const size = format.bytes(&size_buffer, details.size);
                try caption(ImageStep, ui, if (details.compression) |compression|
                    try ui.fmt("{s} \u{00b7} {s}", .{ size, compression })
                else
                    try ui.arena().dupe(u8, size), theme.font(.small, theme.muted));
            },
            .failed => |err| try caption(ImageStep, ui, model.describeError(err), theme.font(.small, theme.danger)),
        }
        if (!props.locked) try theme.link(ImageStep, ui, "remove", "Remove", .remove, theme.accent);
    }
};

/// Step 2: the drive to write to.
pub const TargetStep = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { open };
    pub const Props = struct {
        target: ?*const model.Drive,
        /// Whether an image has been chosen, which comes first.
        enabled: bool,
        locked: bool = false,
        image_size: ?u64 = null,
        icons: *const model.Icons,
        on_open: app.Handler(void),
    };

    pub fn update(_: *State, msg: Msg, ctx: *app.Update(TargetStep)) void {
        switch (msg) {
            .open => ctx.emit(ctx.props.on_open, {}),
        }
    }

    pub fn view(ui: *app.Scope(TargetStep), _: *const State, props: Props) !void {
        try open(TargetStep, ui, props.icons, .drive, if (props.enabled and !props.locked) theme.text else theme.faint, props.target != null);
        defer ui.close();

        const drive = props.target orelse {
            try theme.button(TargetStep, ui, "open", "Select target", .{
                .on_click = if (props.enabled) .open else null,
                .width = button_width,
                .height = button_height,
            });
            return;
        };

        var name_buffer: [64]u8 = undefined;
        var name_style = theme.font(.label, theme.text);
        name_style.wrap_mode = .none;
        try ui.open(null, .{ .layout = .{ .sizing = .{ .height = .fixed(button_height) }, .child_alignment = .center } });
        try ui.text(try ui.arena().dupe(u8, format.middle(&name_buffer, drive.name, 24)), name_style);
        ui.close();

        var size_buffer: [32]u8 = undefined;
        try caption(TargetStep, ui, try ui.arena().dupe(u8, format.bytes(&size_buffer, drive.size)), theme.font(.small, theme.muted));
        if (props.image_size) |size| {
            if (drive.size < size) try caption(TargetStep, ui, "Too small for this image", theme.font(.small, theme.danger));
        }
        if (drive.system) try caption(TargetStep, ui, "System drive", theme.font(.small, theme.danger));
        if (!props.locked) try theme.link(TargetStep, ui, "change", "Change", .open, theme.accent);
    }
};

/// Step 3: the flash button, which becomes a progress bar while flashing.
pub const FlashStep = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { flash, cancel };
    pub const Props = struct {
        /// Whether everything is chosen and fits.
        ready: bool,
        running: ?*const model.Running = null,
        icons: *const model.Icons,
        on_flash: app.Handler(void),
        on_cancel: app.Handler(void),
    };

    pub fn update(_: *State, msg: Msg, ctx: *app.Update(FlashStep)) void {
        switch (msg) {
            .flash => ctx.emit(ctx.props.on_flash, {}),
            .cancel => ctx.emit(ctx.props.on_cancel, {}),
        }
    }

    pub fn view(ui: *app.Scope(FlashStep), _: *const State, props: Props) !void {
        const active = props.ready or props.running != null;
        try open(FlashStep, ui, props.icons, .flash, if (active) theme.text else theme.faint, props.running != null);
        defer ui.close();

        const running = props.running orelse {
            try theme.button(FlashStep, ui, "flash", "Flash!", .{
                .on_click = if (props.ready) .flash else null,
                .width = button_width,
                .height = button_height,
            });
            return;
        };

        try progressBar(ui, running);

        if (running.canceling) {
            try caption(FlashStep, ui, "Canceling\u{2026}", theme.font(.small, theme.muted));
            return;
        }
        if (running.speed > 0) {
            var speed_buffer: [32]u8 = undefined;
            var left_buffer: [32]u8 = undefined;
            const speed = format.speed(&speed_buffer, running.speed);
            try caption(FlashStep, ui, if (running.secondsLeft()) |left|
                try ui.fmt("{s} \u{00b7} ETA {s}", .{ speed, format.duration(&left_buffer, left) })
            else
                try ui.arena().dupe(u8, speed), theme.font(.small, theme.muted));
        } else {
            try caption(FlashStep, ui, " ", theme.font(.small, theme.muted));
        }
        try theme.link(FlashStep, ui, "cancel", "Cancel", .cancel, theme.danger);
    }

    fn progressBar(ui: *app.Scope(FlashStep), running: *const model.Running) !void {
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
        var style = theme.font(.label, .white);
        style.wrap_mode = .none;
        if (fraction) |value| {
            try ui.text(try ui.fmt("{s}\u{2026} {d}%", .{ verb, @as(u32, @intFromFloat(@floor(value * 100))) }), style);
        } else {
            try ui.text(try ui.fmt("{s}\u{2026}", .{verb}), style);
        }
    }
};
