const std = @import("std");

const regular_file = @import("regular_file.zig");
const device = @import("../../device.zig");

pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
    return regular_file.probeTarget(allocator, io, path);
}

pub fn openTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.OpenTarget {
    return regular_file.openTarget(allocator, io, path);
}

pub fn prepareTargetPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return regular_file.prepareTargetPath(allocator, io, path);
}

pub fn prepareTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget) !void {
    return regular_file.prepareTarget(allocator, io, target);
}

pub fn listCandidateDisks(allocator: std.mem.Allocator, io: std.Io, options: device.ListOptions) !device.CandidateDiskList {
    return regular_file.listCandidateDisks(allocator, io, options);
}
