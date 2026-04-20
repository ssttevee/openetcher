const std = @import("std");

const regular_file = @import("regular_file.zig");
const device = @import("../../device.zig");

pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
    return regular_file.probeTarget(allocator, io, path);
}

pub fn openTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.OpenTarget {
    return regular_file.openTarget(allocator, io, path);
}
