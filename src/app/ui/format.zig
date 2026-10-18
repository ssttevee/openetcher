//! Formatting for what the interface shows: sizes, speeds, durations and
//! shortened names.
//!
//! Sizes, speeds and durations are values with a `format` method, so views
//! print them with `{f}`, as in
//! `ui.print(style, "{f} · {s}", .{ format.bytes(size), codec })`.
const std = @import("std");
const Writer = std.Io.Writer;

/// A byte count in decimal units, as drive vendors and Etcher label them:
/// `512 B`, `1.5 kB`, `31.9 GB`.
pub fn bytes(count: u64) Bytes {
    return .{ .count = count };
}

pub const Bytes = struct {
    count: u64,

    pub fn format(self: Bytes, writer: *Writer) Writer.Error!void {
        const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB" };
        if (self.count < 1000) return writer.print("{d} B", .{self.count});

        var value: f64 = @floatFromInt(self.count);
        var unit: usize = 0;
        while (value >= 999.95 and unit + 1 < units.len) : (unit += 1) value /= 1000;
        // three significant digits, like Finder
        return if (value < 10)
            writer.print("{d:.2} {s}", .{ value, units[unit] })
        else if (value < 100)
            writer.print("{d:.1} {s}", .{ value, units[unit] })
        else
            writer.print("{d:.0} {s}", .{ value, units[unit] });
    }
};

/// A transfer rate, such as `85.3 MB/s`.
pub fn speed(bytes_per_second: f64) Speed {
    return .{ .bytes_per_second = bytes_per_second };
}

pub const Speed = struct {
    bytes_per_second: f64,

    pub fn format(self: Speed, writer: *Writer) Writer.Error!void {
        const rounded: u64 = @intFromFloat(@max(0, @round(self.bytes_per_second)));
        return writer.print("{f}/s", .{bytes(rounded)});
    }
};

/// A coarse duration for people: `45s`, `3m 05s`, `1h 02m`.
pub fn duration(seconds: f64) Duration {
    return .{ .seconds = seconds };
}

pub const Duration = struct {
    seconds: f64,

    pub fn format(self: Duration, writer: *Writer) Writer.Error!void {
        const total: u64 = @intFromFloat(@max(0, @round(self.seconds)));
        if (total < 60) return writer.print("{d}s", .{total});
        if (total < 3600) return writer.print("{d}m {d:0>2}s", .{ total / 60, total % 60 });
        return writer.print("{d}h {d:0>2}m", .{ total / 3600, total % 3600 / 60 });
    }
};

/// `text` shortened to at most `max` bytes by cutting out its middle, which
/// keeps both the start and the extension of a file name. Cuts only on
/// UTF-8 character boundaries.
pub fn middle(buffer: []u8, text: []const u8, max: usize) []const u8 {
    const ellipsis = "\u{2026}";
    if (text.len <= max or max <= ellipsis.len + 2) return text;

    const keep = max - ellipsis.len;
    var head = keep / 2;
    var tail_start = text.len - (keep - head);
    while (head > 0 and isContinuation(text[head])) head -= 1;
    while (tail_start < text.len and isContinuation(text[tail_start])) tail_start += 1;

    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ text[0..head], ellipsis, text[tail_start..] }) catch text;
}

fn isContinuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

test bytes {
    try std.testing.expectFmt("0 B", "{f}", .{bytes(0)});
    try std.testing.expectFmt("999 B", "{f}", .{bytes(999)});
    try std.testing.expectFmt("1.50 kB", "{f}", .{bytes(1500)});
    try std.testing.expectFmt("268 MB", "{f}", .{bytes(268_435_456)});
    try std.testing.expectFmt("31.9 GB", "{f}", .{bytes(31_914_983_424)});
    try std.testing.expectFmt("1.00 TB", "{f}", .{bytes(999_999_999_999)});
}

test speed {
    try std.testing.expectFmt("85.3 MB/s", "{f}", .{speed(85_312_000)});
    try std.testing.expectFmt("0 B/s", "{f}", .{speed(-1)});
}

test duration {
    try std.testing.expectFmt("45s", "{f}", .{duration(44.6)});
    try std.testing.expectFmt("3m 05s", "{f}", .{duration(185)});
    try std.testing.expectFmt("1h 02m", "{f}", .{duration(3725)});
}

test middle {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short.img", middle(&buffer, "short.img", 20));
    try std.testing.expectEqualStrings("raspios-b\u{2026}ite.img.xz", middle(&buffer, "raspios-bookworm-arm64-lite.img.xz", 22));
    // never splits a multi-byte character
    const cut = middle(&buffer, "ééééééééééééé.img", 12);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}
