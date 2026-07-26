const std = @import("std");

const range = @import("../range.zig");

pub const ByteRange = range.ByteRange;

pub const Observer = struct {
    context: *anyopaque,
    interested_range_fn: *const fn (context: *anyopaque) ?ByteRange,
    observe_fn: *const fn (context: *anyopaque, absolute_offset: u64, bytes: []const u8) anyerror!void,
    finish_fn: *const fn (context: *anyopaque, image_size: u64) anyerror!void,

    pub fn interestedRange(self: *@This()) ?ByteRange {
        return self.interested_range_fn(self.context);
    }

    pub fn observe(self: *@This(), absolute_offset: u64, bytes: []const u8) !void {
        return self.observe_fn(self.context, absolute_offset, bytes);
    }

    pub fn finish(self: *@This(), image_size: u64) !void {
        return self.finish_fn(self.context, image_size);
    }
};

pub fn deliver(observer: *Observer, offset: u64, bytes: []const u8) !void {
    const interested = observer.interestedRange() orelse return;
    const end = std.math.add(u64, offset, bytes.len) catch return error.RangeOverflow;
    const interested_end = std.math.add(u64, interested.offset, interested.length) catch return error.RangeOverflow;
    const intersection_start = @max(offset, interested.offset);
    const intersection_end = @min(end, interested_end);
    if (intersection_start >= intersection_end) return;
    const start_index: usize = @intCast(intersection_start - offset);
    const end_index: usize = @intCast(intersection_end - offset);
    try observer.observe(intersection_start, bytes[start_index..end_index]);
}
