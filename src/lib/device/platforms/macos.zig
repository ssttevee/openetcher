const std = @import("std");

const regular_file = @import("regular_file.zig");
const device = @import("../../device.zig");

pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false }) catch {
        return regular_file.probeTarget(allocator, io, path);
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind == .file) return regular_file.probeTarget(allocator, io, path);
    if (stat.kind != .block_device and stat.kind != .character_device) return error.UnsupportedTargetType;

    const resolved_path = try resolveDevicePath(allocator, path);
    errdefer allocator.free(resolved_path);

    const size = (try macosDiskSize(io, resolved_path)) orelse return error.UnsupportedTargetType;
    const kind = if (stat.kind == .block_device) device.TargetKind.block_device else device.TargetKind.character_device;

    return .{
        .requested_path = path,
        .resolved_path = resolved_path,
        .capabilities = .{
            .kind = kind,
            .size = size,
            .read_alignment = 512,
            .write_alignment = 512,
            .optimal_io_size = 1024 * 1024,
            .access_pattern = .seek_and_stream,
            .supports_verify_reads = true,
        },
    };
}

pub fn openTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.OpenTarget {
    const info = try probeTarget(allocator, io, path);
    errdefer info.deinit(allocator);

    return .{
        .file = try std.Io.Dir.cwd().openFile(io, info.resolved_path, .{ .mode = .read_write, .allow_directory = false }),
        .info = info,
    };
}

fn resolveDevicePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, "/dev/disk")) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "/dev/r{s}", .{path[5..]});
}

fn macosDiskSize(io: std.Io, path: []const u8) !?u64 {
    if (!std.mem.startsWith(u8, path, "/dev/")) return null;

    const result = try std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "diskutil", "info", path },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(0),
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return parseDiskutilSize(result.stdout);
}

fn parseDiskutilSize(output: []const u8) ?u64 {
    const marker = "Disk Size:";
    const marker_index = std.mem.indexOf(u8, output, marker) orelse return null;
    const tail = output[marker_index + marker.len ..];
    const open_paren = std.mem.indexOfScalar(u8, tail, '(') orelse return null;
    const after_open = tail[open_paren + 1 ..];
    const close_paren = std.mem.indexOfScalar(u8, after_open, ')') orelse return null;
    const paren_text = after_open[0..close_paren];
    const space_index = std.mem.indexOfScalar(u8, paren_text, ' ') orelse return null;
    const bytes_text = std.mem.trim(u8, paren_text[0..space_index], " ");
    return std.fmt.parseInt(u64, bytes_text, 10) catch null;
}

test "parseDiskutilSize reads byte count" {
    const sample =
        "   Disk Size:                 63.9 GB (63864569856 Bytes) (exactly 124735488 512-Byte-Units)\n";

    try std.testing.expectEqual(@as(?u64, 63864569856), parseDiskutilSize(sample));
}
