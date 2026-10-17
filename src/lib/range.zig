const std = @import("std");

const root = @import("../root.zig");

pub const ByteRange = struct {
    offset: u64,
    length: u64,

    /// Callers must have checked that the range does not overflow, as
    /// `normalizeRanges` does. Ranges come from untrusted images, so a
    /// missed check traps here in every build mode instead of being
    /// undefined behavior.
    pub fn end(self: @This()) u64 {
        @setRuntimeSafety(true);
        return std.math.add(u64, self.offset, self.length) catch unreachable;
    }
};

pub fn normalizeRanges(allocator: std.mem.Allocator, input: []const ByteRange) ![]ByteRange {
    var list: std.ArrayList(ByteRange) = .empty;
    defer list.deinit(allocator);

    for (input) |item| {
        if (item.length == 0) continue;
        _ = std.math.add(u64, item.offset, item.length) catch return error.RangeOverflow;
        try list.append(allocator, item);
    }

    std.mem.sort(ByteRange, list.items, {}, lessThan);

    var merged: std.ArrayList(ByteRange) = .empty;
    defer merged.deinit(allocator);

    for (list.items) |item| {
        if (merged.items.len == 0) {
            try merged.append(allocator, item);
            continue;
        }

        var previous = &merged.items[merged.items.len - 1];
        if (item.offset <= previous.end()) {
            const new_end = @max(previous.end(), item.end());
            previous.length = new_end - previous.offset;
            continue;
        }

        try merged.append(allocator, item);
    }

    return merged.toOwnedSlice(allocator);
}

/// Appends `item`, extending the last range instead when `item` starts
/// where it ends. Scanners that emit ranges in ascending order use this to
/// keep one entry per run rather than one per block.
pub fn appendCoalesced(allocator: std.mem.Allocator, list: *std.ArrayList(ByteRange), item: ByteRange) !void {
    if (list.items.len != 0) {
        const last = &list.items[list.items.len - 1];
        const last_end = std.math.add(u64, last.offset, last.length) catch return error.RangeOverflow;
        if (last_end == item.offset) {
            last.length = std.math.add(u64, last.length, item.length) catch return error.RangeOverflow;
            return;
        }
    }
    try list.append(allocator, item);
}

/// Normalizes `input` and requires every range to lie within `[0, size)`.
/// Filesystem parsers use this so a corrupt on-disk pointer becomes an
/// error instead of a plan that writes past the region.
pub fn normalizeWithin(allocator: std.mem.Allocator, input: []const ByteRange, size: u64) ![]ByteRange {
    const normalized = try normalizeRanges(allocator, input);
    errdefer allocator.free(normalized);
    try checkWithin(normalized, size);
    return normalized;
}

/// Fails unless every range ends at or before `size`.
pub fn checkWithin(ranges: []const ByteRange, size: u64) error{ RangeOverflow, RangeOutsideRegion }!void {
    for (ranges) |item| {
        const end = std.math.add(u64, item.offset, item.length) catch return error.RangeOverflow;
        if (end > size) return error.RangeOutsideRegion;
    }
}

fn lessThan(_: void, lhs: ByteRange, rhs: ByteRange) bool {
    if (lhs.offset != rhs.offset) return lhs.offset < rhs.offset;
    return lhs.length < rhs.length;
}

test "normalize ranges merges overlaps and adjacency" {
    const allocator = std.testing.allocator;

    const input = [_]ByteRange{
        .{ .offset = 8192, .length = 1024 },
        .{ .offset = 0, .length = 4096 },
        .{ .offset = 4096, .length = 4096 },
        .{ .offset = 9000, .length = 2000 },
        .{ .offset = 0, .length = 0 },
    };

    const normalized = try normalizeRanges(allocator, &input);
    defer allocator.free(normalized);

    try std.testing.expectEqual(@as(usize, 1), normalized.len);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 0, .length = 11000 }, normalized[0]);
}

test "normalizeWithin rejects ranges past the region" {
    const allocator = std.testing.allocator;
    const input = [_]ByteRange{
        .{ .offset = 0, .length = 512 },
        .{ .offset = 4096, .length = 1024 },
    };

    const inside = try normalizeWithin(allocator, &input, 5120);
    defer allocator.free(inside);
    try std.testing.expectEqual(@as(usize, 2), inside.len);
    try std.testing.expectError(error.RangeOutsideRegion, normalizeWithin(allocator, &input, 5119));
}

test "appendCoalesced merges adjacent ranges only" {
    var list: std.ArrayList(ByteRange) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendCoalesced(std.testing.allocator, &list, .{ .offset = 0, .length = 4 });
    try appendCoalesced(std.testing.allocator, &list, .{ .offset = 4, .length = 4 });
    try appendCoalesced(std.testing.allocator, &list, .{ .offset = 12, .length = 4 });
    try std.testing.expectEqualSlices(ByteRange, &.{ .{ .offset = 0, .length = 8 }, .{ .offset = 12, .length = 4 } }, list.items);
}

test "normalize ranges rejects overflow" {
    const allocator = std.testing.allocator;

    const input = [_]ByteRange{
        .{ .offset = std.math.maxInt(u64), .length = 1 },
    };

    try std.testing.expectError(error.RangeOverflow, normalizeRanges(allocator, &input));
}
