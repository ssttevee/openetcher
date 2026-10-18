//! The screen shown once a flash ends: how it went, and a way to start over.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");

pub const Props = struct {
    outcome: model.FlashOutcome,
    image_name: []const u8,
    drive_name: []const u8,
    on_again: app.Action,
};

pub fn view(ui: *app.Ui, props: Props) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_alignment = .center, .child_gap = 14 } });
    defer ui.close();

    const icon: model.Icon, const color: fabrum.Color, const title: []const u8 = switch (props.outcome) {
        .done => .{ .done, theme.success, "Flash Complete!" },
        .failed => .{ .failed, theme.danger, "Flash Failed" },
        .canceled => .{ .warning, theme.warning, "Flash Canceled" },
    };
    try theme.icon(ui, icon, color, 64);
    try ui.text(title, theme.font(.title, theme.text).with(.{ .alignment = .center }));

    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(480) }, .child_alignment = .top_center } });
        defer ui.close();
        // names too long for a line of their own are cut in the middle
        const detail = theme.font(.body, theme.muted).with(.{ .alignment = .center, .overflow = .ellipsis_middle });
        switch (props.outcome) {
            .done => try ui.print(detail, "{s} was written to {s} and validated.", .{ props.image_name, props.drive_name }),
            .failed => |err| try ui.text(model.describeError(err), detail),
            .canceled => try ui.print(detail, "{s} may be partly written.", .{props.drive_name}),
        }
    }

    switch (props.outcome) {
        .done => |summary| {
            const seconds = @as(f64, @floatFromInt(@max(summary.elapsed_ns, 1))) / std.time.ns_per_s;
            try ui.print(theme.font(.small, theme.faint).with(.{ .wrap_mode = .none }), "Wrote {f} in {f} \u{00b7} {f}", .{
                format.bytes(summary.bytes_written),
                format.duration(seconds),
                format.speed(@as(f64, @floatFromInt(summary.image_size)) / seconds),
            });
        },
        else => {},
    }

    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 14, 0) } });
    defer ui.close();
    try theme.button(ui, "again", "Flash another", .{ .on_click = props.on_again, .width = 170, .height = 44 });
}
