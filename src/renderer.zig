const std = @import("std");
const clay = @import("clay");
const cairo = @import("cairo");

var cairo_context: ?*cairo.Context = null;

pub fn initialize(ctx: *cairo.Context) void {
    cairo_context = ctx;
}

var word_buf: [256]u8 = undefined;

fn nt(s: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(&word_buf, "{s}", .{s}) catch unreachable;
}

pub fn measureText(str: clay.String.Slice, config: *clay.TextElementConfig, user_data: ?*anyopaque) callconv(.C) clay.Dimensions {
    if (str.len == 0) {
        return .{};
    }

    const cr = cairo_context orelse std.debug.panic("not initialized", .{});
    const text = str.asSlice();

    const fonts: *const []const [:0]const u8 = @alignCast(@ptrCast(user_data));

    // Edge case: Clay computes the width of a whitespace character
    // once.  Cairo does not factor in whitespaces when computing text
    // extents, this edge-case serves as a short-circuit to introduce
    // (somewhat) sensible values into Clay.
    if (text.len == 1 and text[0] == ' ') {
        const te = cr.textExtents(nt(text).ptr);
        return .{
            // The multiplication here follows no real logic, just
            // brute-forcing it until the text boundaries look
            // okay-ish.  You should probably rather use a proper text
            // shaping engine like HarfBuzz or Pango.
            .width = @floatCast(te.x_advance * 1.9),
            .height = @floatFromInt(config.font_size),
        };
    }

    // Ensure string is null-terminated for Cairo
    const font_family = fonts.*[config.font_id];

    // Save and reset the Cairo context to avoid unwanted transformations
    cr.save();
    defer cr.restore();

    cr.identityMatrix();

    // Set font properties
    cr.selectFontFace(font_family.ptr, .normal, .normal);
    cr.setFontSize(@floatFromInt(config.font_size));

    // Use glyph extents for better precision
    const scaled_font = cr.getScaledFont() catch |err| {
        std.log.err("failed to get scaled font: {}", .{err});
        return .{};
    };
    // defer scaled_font.deinit();

    const glyphs = scaled_font.textToGlyphs(0, 0, text, null, null) catch |err| {
        std.log.err("failed to generate glyphs: {}", .{err});
        return .{};
    } orelse {
        std.log.err("failed to generate glyphs for string with length {d}: \"{s}\"", .{ text.len, text });
        return .{};
    };
    defer cairo.Glyph.free(glyphs);

    const glyph_extents = cr.glyphExtents(glyphs);

    // Return dimensions
    return .{
        .width = @floatCast(glyph_extents.width),
        .height = @floatCast(glyph_extents.height),
    };
}

fn setCairoColor(cr: *cairo.Context, color: clay.Color) void {
    cr.setSourceRGBA(color.r / 255.0, color.g / 255.0, color.b / 255.0, color.a / 255.0);
}

pub fn render(render_commands: clay.RenderCommandArray, fonts: []const [:0]const u8) void {
    const cr = cairo_context orelse std.debug.panic("not initialized", .{});

    for (render_commands.asSlice()) |command| {
        switch (command.toZig()) {
            .rectangle => |rectangle| {
                const config = rectangle.render_data;
                const bb = rectangle.bounding_box;
                setCairoColor(cr, config.background_color);
                cr.newSubPath();
                cr.arc(bb.x + bb.width - config.corner_radius.bottom_right, bb.y + bb.height - config.corner_radius.bottom_right, config.corner_radius.bottom_right, 0, std.math.pi / 2.0); // 0° to 90°
                cr.arc(bb.x + config.corner_radius.bottom_left, bb.y + bb.height - config.corner_radius.bottom_left, config.corner_radius.bottom_left, std.math.pi / 2.0, std.math.pi); // 90° to 180°
                cr.arc(bb.x + config.corner_radius.top_left, bb.y + config.corner_radius.top_left, config.corner_radius.top_left, std.math.pi, 3.0 * std.math.pi / 2.0); // 180° to 270°
                cr.arc(bb.x + bb.width - config.corner_radius.top_right, bb.y + config.corner_radius.top_right, config.corner_radius.top_right, 3.0 * std.math.pi / 2.0, 2.0 * std.math.pi); // 270° to 360°
                cr.closePath();
                cr.fill();
            },
            .text => |text| {
                const config = text.render_data;
                const bb = text.bounding_box;
                cr.selectFontFace(fonts[config.font_id], .normal, .normal);
                cr.setFontSize(@floatFromInt(config.font_size));
                cr.moveTo(bb.x, bb.y + bb.height);
                setCairoColor(cr, config.text_color);
                cr.showText(nt(config.string_contents.asSlice()));
                cr.closePath();
            },
            .border => |border| {
                const config = border.render_data;
                const bb = border.bounding_box;

                const top_left_radius = config.corner_radius.top_left / 2.0;
                const top_right_radius = config.corner_radius.top_right / 2.0;
                const bottom_right_radius = config.corner_radius.bottom_right / 2.0;
                const bottom_left_radius = config.corner_radius.bottom_left / 2.0;

                setCairoColor(cr, config.color);

                if (config.width.top > 0) {
                    cr.setLineWidth(@floatFromInt(config.width.top));
                    cr.newSubPath();
                    cr.arc(bb.x + top_left_radius, bb.y + top_left_radius, top_left_radius, 5.0 * std.math.pi / 4.0, 6.0 * std.math.pi / 4.0);
                    cr.lineTo(bb.x + bb.width - top_right_radius, bb.y);
                    cr.arc(bb.x + bb.width - top_right_radius, bb.y + top_right_radius, top_right_radius, 6.0 * std.math.pi / 4.0, 7.0 * std.math.pi / 4.0);
                    cr.stroke();
                }

                if (config.width.right > 0) {
                    cr.setLineWidth(@floatFromInt(config.width.right));
                    cr.newSubPath();
                    cr.arc(bb.x + bb.width - top_right_radius, bb.y + top_right_radius, top_right_radius, 7.0 * std.math.pi / 4.0, 8.0 * std.math.pi / 4.0);
                    cr.lineTo(bb.x + bb.width, bb.y + bb.height - bottom_right_radius);
                    cr.arc(bb.x + bb.width - bottom_right_radius, bb.y + bb.height - bottom_right_radius, bottom_right_radius, 0.0 * std.math.pi / 4.0, 1.0 * std.math.pi / 4.0);
                    cr.stroke();
                }

                if (config.width.bottom > 0) {
                    cr.setLineWidth(@floatFromInt(config.width.bottom));
                    cr.newSubPath();
                    cr.arc(bb.x + bb.width - bottom_right_radius, bb.y + bb.height - bottom_right_radius, bottom_right_radius, 1.0 * std.math.pi / 4.0, 2.0 * std.math.pi / 4.0);
                    cr.lineTo(bb.x + bottom_left_radius, bb.y + bb.height);
                    cr.arc(bb.x + bottom_left_radius, bb.y + bb.height - bottom_left_radius, bottom_left_radius, 2.0 * std.math.pi / 4.0, 3.0 * std.math.pi / 4.0);
                    cr.stroke();
                }

                if (config.width.left > 0) {
                    cr.setLineWidth(@floatFromInt(config.width.left));
                    cr.newSubPath();
                    cr.arc(bb.x + bottom_left_radius, bb.y + bb.height - bottom_left_radius, bottom_left_radius, 3.0 * std.math.pi / 4.0, 4.0 * std.math.pi / 4.0);
                    cr.lineTo(bb.x, bb.y + top_left_radius);
                    cr.arc(bb.x + top_left_radius, bb.y + top_left_radius, top_left_radius, 4.0 * std.math.pi / 4.0, 5.0 * std.math.pi / 4.0);
                    cr.stroke();
                }
            },
            .image => |image| {
                const config = image.render_data;
                const bb = image.bounding_box;

                const image_surface: *cairo.Surface = @alignCast(@ptrCast(config.image_data));

                const image_w: f64 = @floatFromInt(image_surface.getWidth());
                const image_h: f64 = @floatFromInt(image_surface.getHeight());

                // Calculate the scaling factor to fit within the bounding box while preserving aspect ratio
                const scale_w = @as(f64, bb.width) / image_w;
                const scale_h = @as(f64, bb.height) / image_h;
                const scale = @min(scale_w, scale_h);

                // Calculate the scaled image dimensions
                const scaled_w = image_w * scale;
                const scaled_h = image_h * scale;

                // Adjust the x and y coordinates to center the scaled image within the bounding box
                const centered_x = @as(f64, bb.x) + (@as(f64, bb.width) - scaled_w) / 2.0;
                const centered_y = @as(f64, bb.y) + (@as(f64, bb.height) - scaled_h) / 2.0;

                // Blit the scaled and centered image
                cr.save();
                defer cr.restore();

                cr.translate(centered_x, centered_y);
                cr.scale(scale, scale);
                cr.setSourceSurface(image_surface, 0, 0);
                cr.paint();
            },
            .scissor_start => |ss| {
                const bb = ss.bounding_box;

                cr.save();

                cr.newSubPath();
                cr.moveTo(bb.x, bb.y);
                cr.lineTo(bb.x + bb.width, bb.y);
                cr.lineTo(bb.x + bb.width, bb.y + bb.height);
                cr.lineTo(bb.x, bb.y + bb.height);
                cr.closePath();
                cr.clip();
            },
            .scissor_end => {
                cr.restore();
            },
            else => |cmd| {
                std.debug.print("unhandled command type: {s}\n", .{@tagName(cmd)});
            },
        }
    }
}
