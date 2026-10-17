//! The unit of every `std.Progress` count the library reports.
//!
//! Progress counters are saturating u32s, so counting bytes would stall at
//! 4 GiB, below many SD cards. Counting KiB lasts to 4 TiB, past realistic
//! flash targets, and still moves visibly for small images.

const std = @import("std");

pub const bytes_per_unit = 1024;

/// `bytes` in progress units. Rounding up keeps a nonzero total from
/// reading as unknown and lets the final count reach the total.
pub fn fromBytes(bytes: u64) usize {
    return std.math.lossyCast(usize, std.math.divCeil(u64, bytes, bytes_per_unit) catch unreachable);
}

test "progress units round bytes up to whole KiB" {
    try std.testing.expectEqual(@as(usize, 0), fromBytes(0));
    try std.testing.expectEqual(@as(usize, 1), fromBytes(1));
    try std.testing.expectEqual(@as(usize, 1), fromBytes(1024));
    try std.testing.expectEqual(@as(usize, 2), fromBytes(1025));
    // A 2 TiB disk stays well inside the u32 counters.
    try std.testing.expect(fromBytes(2 << 40) < std.math.maxInt(u32));
}
