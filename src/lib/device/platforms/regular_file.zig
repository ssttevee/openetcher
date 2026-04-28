const std = @import("std");

const device = @import("../../device.zig");

pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedTargetType;

    return .{
        .requested_path = path,
        .resolved_path = try allocator.dupe(u8, path),
        .capabilities = .{
            .kind = .regular_file,
            .size = stat.size,
            .read_alignment = 1,
            .write_alignment = 1,
            .optimal_io_size = stat.block_size,
            .access_pattern = .positional,
            .supports_verify_reads = true,
        },
    };
}

pub fn openTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.OpenTarget {
    const info = try probeTarget(allocator, io, path);
    errdefer info.deinit(allocator);

    return .{
        .file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .allow_directory = false }),
        .info = info,
    };
}

pub fn prepareTargetPath(_: std.mem.Allocator, _: std.Io, _: []const u8) !void {}

pub fn prepareTarget(_: std.mem.Allocator, _: std.Io, _: *device.OpenTarget) !void {}

pub fn listCandidateDisks(allocator: std.mem.Allocator, _: std.Io, _: device.ListOptions) !device.CandidateDiskList {
    return .{ .items = try allocator.alloc(device.CandidateDisk, 0) };
}

pub fn resolveDiskId(_: std.mem.Allocator, _: std.Io, _: []const u8, _: device.ResolveDiskIdOptions) ![]u8 {
    return error.UnsupportedTargetType;
}

pub fn lookupDiskByPath(_: std.mem.Allocator, _: std.Io, _: []const u8, _: device.LookupDiskOptions) !?device.CandidateDisk {
    return null;
}
