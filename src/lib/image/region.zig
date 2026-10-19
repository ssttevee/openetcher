const std = @import("std");

const range = @import("../range.zig");

pub const ByteRange = range.ByteRange;

pub const Region = struct {
    offset: u64,
    length: u64,

    pub fn end(self: @This()) !u64 {
        return std.math.add(u64, self.offset, self.length);
    }

    pub fn contains(self: @This(), relative: ByteRange) !bool {
        const relative_end = std.math.add(u64, relative.offset, relative.length) catch return error.RangeOverflow;
        return relative_end <= self.length;
    }

    pub fn toImageOffset(self: @This(), relative_offset: u64) !u64 {
        if (relative_offset > self.length) return error.RegionOutOfBounds;
        return std.math.add(u64, self.offset, relative_offset);
    }

    pub fn toImageRange(self: @This(), relative: ByteRange) !ByteRange {
        if (!try self.contains(relative)) return error.RegionOutOfBounds;
        return .{
            .offset = try self.toImageOffset(relative.offset),
            .length = relative.length,
        };
    }

    pub fn slice(self: @This(), relative_offset: u64, length: u64) !Region {
        const relative = try self.toImageRange(.{ .offset = relative_offset, .length = length });
        return .{ .offset = relative.offset, .length = relative.length };
    }
};

test "region translates bounded ranges" {
    const region = Region{ .offset = 4096, .length = 8192 };
    try std.testing.expectEqualDeep(ByteRange{ .offset = 5120, .length = 1024 }, try region.toImageRange(.{ .offset = 1024, .length = 1024 }));
    try std.testing.expectError(error.RegionOutOfBounds, region.toImageRange(.{ .offset = 8192, .length = 1 }));
}

test "region detects arithmetic overflow" {
    const region = Region{ .offset = std.math.maxInt(u64), .length = 1 };
    try std.testing.expectError(error.Overflow, region.end());
    try std.testing.expectError(error.RangeOverflow, region.contains(.{ .offset = std.math.maxInt(u64), .length = 1 }));
}
