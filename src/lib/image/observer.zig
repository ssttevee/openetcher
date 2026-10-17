const std = @import("std");

const range = @import("../range.zig");

pub const ByteRange = range.ByteRange;

/// Sees the image bytes in one range as a flash writes them.
///
/// Observers are caller code, so this stays an interface. Failures report
/// `ObserverFailed`, as `std.Io.Reader` reports `ReadFailed`: an observer
/// that needs the cause keeps it in its own context. A fixed error set keeps
/// the flash engine's errors precise.
pub const Observer = struct {
    context: *anyopaque,
    interested_range_fn: *const fn (context: *anyopaque) ?ByteRange,
    observe_fn: *const fn (context: *anyopaque, absolute_offset: u64, bytes: []const u8) Error!void,
    finish_fn: *const fn (context: *anyopaque, image_size: u64) Error!void,

    pub const Error = error{ObserverFailed};

    pub fn interestedRange(self: *@This()) ?ByteRange {
        return self.interested_range_fn(self.context);
    }

    pub fn observe(self: *@This(), absolute_offset: u64, bytes: []const u8) Error!void {
        return self.observe_fn(self.context, absolute_offset, bytes);
    }

    pub fn finish(self: *@This(), image_size: u64) Error!void {
        return self.finish_fn(self.context, image_size);
    }
};

pub fn deliver(observer: *Observer, offset: u64, bytes: []const u8) (Observer.Error || error{RangeOverflow})!void {
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
