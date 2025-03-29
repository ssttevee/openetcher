const std = @import("std");
const clay = @import("clay");
const cairo = @import("cairo");

fn mergeCommands(comptime commands: anytype) []const cairo.Path.Data {
    var data: []const cairo.Path.Data = &.{};
    for (commands) |command| {
        data = data ++ &command;
    }

    return data;
}

fn createCommand(comptime data_type: cairo.Path.Data.Type, points: anytype) [points.len + 1]cairo.Path.Data {
    return comptime [_]cairo.Path.Data{.{ .header = .{ .type = data_type, .length = 1 + points.len } }} ++ points;
}

fn moveTo(comptime x: f64, comptime y: f64) [2]cairo.Path.Data {
    return createCommand(
        .move_to,
        [_]cairo.Path.Data{
            .{
                .point = .{
                    .x = x,
                    .y = y,
                },
            },
        },
    );
}

fn lineTo(comptime x: f64, comptime y: f64) [2]cairo.Path.Data {
    return createCommand(
        .line_to,
        [_]cairo.Path.Data{
            .{
                .point = .{
                    .x = x,
                    .y = y,
                },
            },
        },
    );
}

fn curveTo(comptime c1_x: f64, comptime c1_y: f64, comptime c2_x: f64, comptime c2_y: f64, comptime x: f64, comptime y: f64) [4]cairo.Path.Data {
    return createCommand(
        .curve_to,
        [_]cairo.Path.Data{
            .{
                .point = .{
                    .x = c1_x,
                    .y = c1_y,
                },
            },
            .{
                .point = .{
                    .x = c2_x,
                    .y = c2_y,
                },
            },
            .{
                .point = .{
                    .x = x,
                    .y = y,
                },
            },
        },
    );
}

fn closePath() [1]cairo.Path.Data {
    return createCommand(
        .close_path,
        [_]cairo.Path.Data{},
    );
}

const arc = struct {
    // based on https://github.com/fontello/svgpath/blob/master/lib/a2c.js

    /// Calculate an angle between two unit vectors
    ///
    /// Since we measure angle between radii of circular arcs,
    /// we can use simplified math (without length normalization)
    fn unitVectorAngle(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
        return (@as(f64, @floatFromInt(@intFromBool(ux * vy - uy * vx >= 0))) * 2 - 1) * std.math.acos(std.math.clamp(ux * vx + uy * vy, -1.0, 1.0));
    }

    const ArcPrelude = struct {
        cos_phi: f64,
        sin_phi: f64,
        radius_x: f64,
        radius_y: f64,
        center_x: f64,
        center_y: f64,
        start_theta: f64,
        delta_theta: f64,
        segments: usize,
    };

    fn arcPrelude(start_x: f64, start_y: f64, radius_x: f64, radius_y: f64, phi: f64, large_arc: bool, sweep_clockwise: bool, end_x: f64, end_y: f64) ?ArcPrelude {
        if (radius_x == 0 or radius_y == 0) {
            // one of the radii is zero
            return null;
        }

        // Make sure radii are valid
        const sin_phi = @sin(phi * std.math.pi / 180);
        const cos_phi = @cos(phi * std.math.pi / 180);
        const x1p = cos_phi * (start_x - end_x) / 2 + sin_phi * (start_y - end_y) / 2;
        const y1p = -sin_phi * (start_x - end_x) / 2 + cos_phi * (start_y - end_y) / 2;

        if (x1p == 0 and y1p == 0) {
            // we're asked to draw line to itself
            return null;
        }

        // Compensate out-of-range radii
        //
        var rx = @abs(radius_x);
        var ry = @abs(radius_y);

        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }

        // Convert from endpoint to center parameterization,
        // see http://www.w3.org/TR/SVG11/implnote.html#ArcImplementationNotes
        const cx, const cy, const theta1, const delta_theta = blk: {
            // Step 1.
            //
            // Move an ellipse so origin will be the middlepoint between our two
            // points and rotate it to line up the ellipse axes with coordinate
            // axes.

            const rx_sq = rx * rx;
            const ry_sq = ry * ry;
            const x1p_sq = x1p * x1p;
            const y1p_sq = y1p * y1p;

            // Step 2.
            //
            // Compute coordinates of the centre of this ellipse (cx', cy')
            // in the new coordinate system.
            const radicant = @sqrt(@max(0, (rx_sq * ry_sq) - (rx_sq * y1p_sq) - (ry_sq * x1p_sq)) / ((rx_sq * y1p_sq) + (ry_sq * x1p_sq))) * (@as(f64, @floatFromInt(@intFromBool(large_arc != sweep_clockwise))) * 2 - 1);

            const cxp = radicant * rx / ry * y1p;
            const cyp = radicant * -ry / rx * x1p;

            const v1x = (x1p - cxp) / rx;
            const v1y = (y1p - cyp) / ry;
            const v2x = (-x1p - cxp) / rx;
            const v2y = (-y1p - cyp) / ry;

            break :blk .{
                // Step 3.
                //
                // Transform back to get centre coordinates (cx, cy) in the original
                // coordinate system.
                cos_phi * cxp - sin_phi * cyp + (start_x + end_x) / 2,
                sin_phi * cxp + cos_phi * cyp + (start_y + end_y) / 2,

                // Step 4.
                //
                // Compute angles (theta1, delta_theta).
                //
                unitVectorAngle(1, 0, v1x, v1y),
                blk2: {
                    const delta_theta = unitVectorAngle(v1x, v1y, v2x, v2y);
                    break :blk2 delta_theta + (@as(f64, @floatFromInt(@intFromBool(sweep_clockwise and delta_theta < 0))) - @as(f64, @floatFromInt(@intFromBool(!sweep_clockwise and delta_theta > 0)))) * std.math.tau;
                },
            };
        };

        return .{
            // Split an arc to multiple segments, so each segment
            // will be less than 90°
            .segments = @intFromFloat(@ceil(@max(@abs(delta_theta) / (std.math.pi / 2.0), 1.0))),
            .sin_phi = sin_phi,
            .cos_phi = cos_phi,
            .radius_x = rx,
            .radius_y = ry,
            .center_x = cx,
            .center_y = cy,
            .start_theta = theta1,
            .delta_theta = delta_theta,
        };
    }

    fn arc(start_x: f64, start_y: f64, radius_x: f64, radius_y: f64, phi: f64, large_arc: bool, sweep_clockwise: bool, end_x: f64, end_y: f64) [
        (if (arcPrelude(start_x, start_y, radius_x, radius_y, phi, large_arc, sweep_clockwise, end_x, end_y)) |p| p.segments else 0) * 4
    ]cairo.Path.Data {
        const prelude = arcPrelude(start_x, start_y, radius_x, radius_y, phi, large_arc, sweep_clockwise, end_x, end_y) orelse return .{};
        const segment_delta_theta = prelude.delta_theta / @as(f64, @floatFromInt(prelude.segments));
        const alpha = 4.0 / 3.0 * @tan(segment_delta_theta / 4.0);

        comptime var curves: [prelude.segments][4]cairo.Path.Data = undefined;
        inline for (0..prelude.segments) |i| {
            // generate an approximation of the arc on a unit circle
            const segment_start_theta = prelude.start_theta + segment_delta_theta * i;
            const segment_end_theta = prelude.start_theta + segment_delta_theta * (i + 1);

            const x1 = @cos(segment_start_theta);
            const y1 = @sin(segment_start_theta);
            const x2 = @cos(segment_end_theta);
            const y2 = @sin(segment_end_theta);

            const points = [_][2]f64{
                // .{ x1, y1 },
                .{ x1 - y1 * alpha, y1 + x1 * alpha },
                .{ x2 + y2 * alpha, y2 - x2 * alpha },
                .{ x2, y2 },
            };

            // map the arc to the ellipse
            curves[i] = createCommand(
                .curve_to,
                blk: {
                    var pts: [3]cairo.Path.Data = undefined;
                    for (0..points.len) |j| {
                        var x, var y = points[j];

                        // scale
                        x *= prelude.radius_x;
                        y *= prelude.radius_y;

                        // rotate
                        const xp = prelude.cos_phi * x - prelude.sin_phi * y;
                        const yp = prelude.sin_phi * x + prelude.cos_phi * y;

                        // translate
                        pts[j] = .{
                            .point = .{
                                .x = xp + prelude.center_x,
                                .y = yp + prelude.center_y,
                            },
                        };
                    }

                    break :blk pts;
                },
            );
        }

        return @bitCast(curves);
    }
}.arc;

pub const SVGInfo = struct {
    path: *const cairo.Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    width: f64,
    height: f64,
};

const parsePath = struct {
    fn readNumber(path: []const u8, pos: usize) struct { usize, f64 } {
        const start = std.mem.indexOfNonePos(u8, path, pos, " ,") orelse pos;
        var end = std.mem.indexOfNonePos(u8, path, start + @intFromBool(path[start] == '-'), "0123456789.") orelse path.len;
        if (std.mem.indexOfScalarPos(u8, path, start, '.')) |dot_pos| {
            if (dot_pos < end) {
                if (std.mem.indexOfScalarPos(u8, path, dot_pos + 1, '.')) |second_dot_pos| {
                    if (second_dot_pos < end) {
                        end = second_dot_pos;
                    }
                }
            }
        }

        return .{
            end,
            std.fmt.parseFloat(f64, path[start..end]) catch {
                @compileLog(path, start, end);
                unreachable;
            },
        };
    }

    fn parsePath(comptime scale: f64, comptime path: []const u8) SVGInfo {
        @setEvalBranchQuota(100000);

        const svg_commands = "MmLlHhVvCcSsQqTtAaZz";

        var last_x: f64 = 0;
        var last_y: f64 = 0;

        var pos: usize = 0;
        var commands: []const cairo.Path.Data = &.{};
        while (std.mem.indexOfAnyPos(u8, path, pos, svg_commands)) |index| {
            const c = path[index];
            pos = index + 1;
            switch (c) {
                'M' => {
                    pos, last_x = readNumber(path, pos);
                    pos, last_y = readNumber(path, pos);
                    commands = commands ++ moveTo(last_x * scale, last_y * scale);
                },
                'm' => {
                    pos, const delta_x = readNumber(path, pos);
                    pos, const delta_y = readNumber(path, pos);
                    last_x += delta_x;
                    last_y += delta_y;
                    commands = commands ++ moveTo(last_x * scale, last_y * scale);
                },
                'L' => {
                    pos, last_x = readNumber(path, pos);
                    pos, last_y = readNumber(path, pos);
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'l' => {
                    pos, const delta_x = readNumber(path, pos);
                    pos, const delta_y = readNumber(path, pos);
                    last_x += delta_x;
                    last_y += delta_y;
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'H' => {
                    pos, last_x = readNumber(path, pos);
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'h' => {
                    pos, const delta_x = readNumber(path, pos);
                    last_x += delta_x;
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'V' => {
                    pos, last_y = readNumber(path, pos);
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'v' => {
                    pos, const delta_y = readNumber(path, pos);
                    last_y += delta_y;
                    commands = commands ++ lineTo(last_x * scale, last_y * scale);
                },
                'C' => {
                    pos, const c1_x = readNumber(path, pos);
                    pos, const c1_y = readNumber(path, pos);
                    pos, const c2_x = readNumber(path, pos);
                    pos, const c2_y = readNumber(path, pos);
                    pos, last_x = readNumber(path, pos);
                    pos, last_y = readNumber(path, pos);
                    commands = commands ++ curveTo(c1_x * scale, c1_y * scale, c2_x * scale, c2_y * scale, last_x * scale, last_y * scale);
                },
                'c' => {
                    pos, const c1_x = readNumber(path, pos);
                    pos, const c1_y = readNumber(path, pos);
                    pos, const c2_x = readNumber(path, pos);
                    pos, const c2_y = readNumber(path, pos);
                    pos, const delta_x = readNumber(path, pos);
                    pos, const delta_y = readNumber(path, pos);
                    last_x += delta_x;
                    last_y += delta_y;
                    commands = commands ++ curveTo(c1_x * scale, c1_y * scale, c2_x * scale, c2_y * scale, last_x * scale, last_y * scale);
                },
                'S' => @panic("not implemented"),
                's' => @panic("not implemented"),
                'Q' => @panic("not implemented"),
                'q' => @panic("not implemented"),
                'T' => @panic("not implemented"),
                't' => @panic("not implemented"),
                'A' => {
                    pos, const rx = readNumber(path, pos);
                    pos, const ry = readNumber(path, pos);
                    pos, const angle = readNumber(path, pos);
                    pos, const large_arc_flag = readNumber(path, pos);
                    pos, const sweep_flag = readNumber(path, pos);
                    pos, const x = readNumber(path, pos);
                    pos, const y = readNumber(path, pos);
                    commands = commands ++ arc(last_x * scale, last_y * scale, rx * scale, ry * scale, angle, large_arc_flag == 1, sweep_flag == 1, x * scale, y * scale);
                    // _ = rx;
                    // _ = ry;
                    // _ = angle;
                    // _ = large_arc_flag;
                    // _ = sweep_flag;
                    // commands = commands ++ lineTo(x * scale, y * scale);
                    last_x = x;
                    last_y = y;
                },
                'a' => {
                    pos, const rx = readNumber(path, pos);
                    pos, const ry = readNumber(path, pos);
                    pos, const angle = readNumber(path, pos);
                    pos, const large_arc_flag = readNumber(path, pos);
                    pos, const sweep_flag = readNumber(path, pos);
                    pos, const x = readNumber(path, pos);
                    pos, const y = readNumber(path, pos);
                    commands = commands ++ arc(last_x * scale, last_y * scale, rx * scale, ry * scale, angle, large_arc_flag == 1, sweep_flag == 1, (last_x + x) * scale, (last_y + y) * scale);
                    // _ = rx;
                    // _ = ry;
                    // _ = angle;
                    // _ = large_arc_flag;
                    // _ = sweep_flag;
                    // commands = commands ++ lineTo((last_x + x) * scale, (last_y + y) * scale);
                    last_x += x;
                    last_y += y;
                },
                'Z', 'z' => {
                    commands = commands ++ closePath();
                },
                else => unreachable,
            }
        }

        var min_x: f64 = std.math.floatMax(f64);
        var min_y: f64 = std.math.floatMax(f64);
        var max_x: f64 = std.math.floatMin(f64);
        var max_y: f64 = std.math.floatMin(f64);
        var i: usize = 0;
        while (i < commands.len) {
            const command = commands[i];
            for (0..@intCast(command.header.length - 1)) |j| {
                const point = commands[i + j + 1].point;
                if (point.x < min_x) {
                    min_x = point.x;
                }

                if (point.x > max_x) {
                    max_x = point.x;
                }

                if (point.y < min_y) {
                    min_y = point.y;
                }

                if (point.y > max_y) {
                    max_y = point.y;
                }
            }

            i += @as(usize, @intCast(command.header.length));
        }

        return .{
            .path = comptime &.{
                .status = .success,
                .data = commands.ptr,
                .num_data = commands.len,
            },
            .x1 = min_x,
            .y1 = min_y,
            .x2 = max_x,
            .y2 = max_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
}.parsePath;

test parsePath {
    const info = comptime parsePath(1, "m5.5-6.343");
    try std.testing.expectEqual(2, info.path.num_data);
    try std.testing.expectEqual(@as(f64, 5.5), info.path.data[1].point.x);
    try std.testing.expectEqual(@as(f64, -6.343), info.path.data[1].point.y);
}

const paths = struct {
    pub const add_document = "M9.293 0H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V4.707A1 1 0 0 0 13.707 4L10 .293A1 1 0 0 0 9.293 0M9.5 3.5v-2l3 3h-2a1 1 0 0 1-1-1M8.5 7v1.5H10a.5.5 0 0 1 0 1H8.5V11a.5.5 0 0 1-1 0V9.5H6a.5.5 0 0 1 0-1h1.5V7a.5.5 0 0 1 1 0";
    pub const hdd = "M0 10a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v1a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2zm2.5 1a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1m2 0a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1M.91 7.204A3 3 0 0 1 2 7h12c.384 0 .752.072 1.09.204l-1.867-3.422A1.5 1.5 0 0 0 11.906 3H4.094a1.5 1.5 0 0 0-1.317.782z";
    pub const bolt = "M12.307,24H8.073L10.1,16H6.965A2.99,2.99,0,0,1,4.1,12.144L8.443,0h9.626L15.228,7h2.808A2.962,2.962,0,0,1,20.5,11.6ZM13.95,13l-1.259,4.979L18,9.943,10.772,10l2.842-7H10.557L6.951,13.083Z";
    pub const circle = "M0 8a8 8 0 0 1 8-8a8 8 0 0 1 8 8a8 8 0 0 1-8 8a8 8 0 0 1-8-8z";
};

const SVGSurface = struct {
    surface: *cairo.Surface,
    width: u32,
    height: u32,
};

pub fn clayImage(comptime svg: std.meta.DeclEnum(paths), comptime scale: f64, comptime fill: clay.Color, sizing: clay.Sizing) void {
    const surface, const extents = struct {
        const info = parsePath(scale, @field(paths, @tagName(svg)));
        var cached_surface: ?struct { *cairo.Surface, cairo.Extents } = null;

        fn loadSurface() !struct { *cairo.Surface, cairo.Extents } {
            if (cached_surface == null) {
                const surface = try cairo.Surface.initImage(.argb32, @intFromFloat(info.x2), @intFromFloat(info.y2));
                errdefer surface.deinit();

                const ctx = try cairo.Context.init(surface);
                defer ctx.deinit();

                try ctx.appendPath(info.path);
                const extents = ctx.extents();
                ctx.setSourceRGBA(fill.r, fill.g, fill.b, fill.a);
                ctx.fill();

                cached_surface = .{
                    surface,
                    extents,
                };
            }

            return cached_surface orelse unreachable;
        }
    }.loadSurface() catch unreachable;

    clay.ui()(.{
        .layout = .{
            .sizing = sizing,
        },
        .image = .{
            .image_data = surface,
            .source_dimensions = .{
                .width = @floatCast(extents.x2 - extents.x1),
                .height = @floatCast(extents.y2 - extents.y1),
            },
        },
    })({});
}
