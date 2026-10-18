//! Formatting for what the interface shows: sizes, speeds, durations and
//! shortened names.
const std = @import("std");

/// A byte count in decimal units, as drive vendors and Etcher label them:
/// `512 B`, `1.5 kB`, `31.9 GB`.
pub fn bytes(buffer: []u8, count: u64) []const u8 {
    const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB" };
    if (count < 1000) return std.fmt.bufPrint(buffer, "{d} B", .{count}) catch buffer[0..0];

    var value: f64 = @floatFromInt(count);
    var unit: usize = 0;
    while (value >= 999.95 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    // three significant digits, like Finder
    const precision: usize = if (value < 10) 2 else if (value < 100) 1 else 0;
    return switch (precision) {
        2 => std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ value, units[unit] }),
        1 => std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }),
        else => std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ value, units[unit] }),
    } catch buffer[0..0];
}

/// A transfer rate, such as `85.3 MB/s`.
pub fn speed(buffer: []u8, bytes_per_second: f64) []const u8 {
    var unit_buffer: [32]u8 = undefined;
    const rounded: u64 = @intFromFloat(@max(0, @round(bytes_per_second)));
    return std.fmt.bufPrint(buffer, "{s}/s", .{bytes(&unit_buffer, rounded)}) catch buffer[0..0];
}

/// A coarse duration for people: `45s`, `3m 05s`, `1h 02m`.
pub fn duration(buffer: []u8, seconds: f64) []const u8 {
    const total: u64 = @intFromFloat(@max(0, @round(seconds)));
    if (total < 60) return std.fmt.bufPrint(buffer, "{d}s", .{total}) catch buffer[0..0];
    if (total < 3600) return std.fmt.bufPrint(buffer, "{d}m {d:0>2}s", .{ total / 60, total % 60 }) catch buffer[0..0];
    return std.fmt.bufPrint(buffer, "{d}h {d:0>2}m", .{ total / 3600, total % 3600 / 60 }) catch buffer[0..0];
}

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
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buffer, 0));
    try std.testing.expectEqualStrings("999 B", bytes(&buffer, 999));
    try std.testing.expectEqualStrings("1.50 kB", bytes(&buffer, 1500));
    try std.testing.expectEqualStrings("268 MB", bytes(&buffer, 268_435_456));
    try std.testing.expectEqualStrings("31.9 GB", bytes(&buffer, 31_914_983_424));
    try std.testing.expectEqualStrings("1.00 TB", bytes(&buffer, 999_999_999_999));
}

test speed {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("85.3 MB/s", speed(&buffer, 85_312_000));
    try std.testing.expectEqualStrings("0 B/s", speed(&buffer, -1));
}

test duration {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45s", duration(&buffer, 44.6));
    try std.testing.expectEqualStrings("3m 05s", duration(&buffer, 185));
    try std.testing.expectEqualStrings("1h 02m", duration(&buffer, 3725));
}

test middle {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short.img", middle(&buffer, "short.img", 20));
    try std.testing.expectEqualStrings("raspios-b\u{2026}ite.img.xz", middle(&buffer, "raspios-bookworm-arm64-lite.img.xz", 22));
    // never splits a multi-byte character
    const cut = middle(&buffer, "ééééééééééééé.img", 12);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}
