//! The screen shown once a flash ends: how it went, and a way to start over.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");

const Finish = @This();

pub const State = struct {};

pub const Msg = union(enum) { again };

pub const Props = struct {
    outcome: model.FlashOutcome,
    image_name: []const u8,
    drive_name: []const u8,
    icons: *const model.Icons,
    on_again: app.Handler(void),
};

pub fn update(_: *State, msg: Msg, ctx: *app.Update(Finish)) void {
    switch (msg) {
        .again => ctx.emit(ctx.props.on_again, {}),
    }
}

pub fn view(ui: *app.Scope(Finish), _: *const State, props: Props) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_alignment = .center, .child_gap = 14 } });
    defer ui.close();

    var image_buffer: [64]u8 = undefined;
    var drive_buffer: [64]u8 = undefined;
    const image = format.middle(&image_buffer, props.image_name, 40);
    const drive = format.middle(&drive_buffer, props.drive_name, 32);

    const icon: model.Icon, const color: fabrum.Color, const title: []const u8, const detail: []const u8 = switch (props.outcome) {
        .done => .{ .done, theme.success, "Flash Complete!", try ui.fmt("{s} was written to {s} and validated.", .{ image, drive }) },
        .failed => |err| .{ .failed, theme.danger, "Flash Failed", model.describeError(err) },
        .canceled => .{ .warning, theme.warning, "Flash Canceled", try ui.fmt("{s} may be partly written.", .{drive}) },
    };

    try theme.icon(Finish, ui, try props.icons.content(ui.arena(), icon, color), 64);

    var title_style = theme.font(.title, theme.text);
    title_style.alignment = .center;
    try ui.text(title, title_style);

    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(480) }, .child_alignment = .top_center } });
    var detail_style = theme.font(.body, theme.muted);
    detail_style.alignment = .center;
    try ui.text(detail, detail_style);
    ui.close();

    switch (props.outcome) {
        .done => |summary| {
            var written_buffer: [32]u8 = undefined;
            var time_buffer: [32]u8 = undefined;
            var speed_buffer: [32]u8 = undefined;
            const seconds = @as(f64, @floatFromInt(@max(summary.elapsed_ns, 1))) / std.time.ns_per_s;
            var stats_style = theme.font(.small, theme.faint);
            stats_style.wrap_mode = .none;
            try ui.text(try ui.fmt("Wrote {s} in {s} \u{00b7} {s}", .{
                format.bytes(&written_buffer, summary.bytes_written),
                format.duration(&time_buffer, seconds),
                format.speed(&speed_buffer, @as(f64, @floatFromInt(summary.image_size)) / seconds),
            }), stats_style);
        },
        else => {},
    }

    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 14, 0) } });
    defer ui.close();
    try theme.button(Finish, ui, "again", "Flash another", .{ .on_click = .again, .width = 170, .height = 44 });
}
