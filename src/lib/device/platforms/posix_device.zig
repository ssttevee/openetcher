//! The target operations macOS and Linux share. Both open a device node,
//! size it with ioctls, and unmount its disk before writing; what differs
//! is supplied by the platform as a namespace of declarations, so each
//! backend keeps its own ioctls and unmount logic private.

const std = @import("std");

const device = @import("../../device.zig");
const regular_file = @import("regular_file.zig");

/// What a device's ioctls report about it.
pub const Geometry = struct { size: u64, block_size: u32 };

/// The target operations for a platform, which declares:
///
/// - `accepts_character_devices: bool`, whether character device nodes
///   are disks, as macOS's raw `/dev/rdiskN` nodes are.
/// - `fn geometry(fd: std.posix.fd_t) ?Geometry`, null when the node is
///   not a disk the platform can size.
/// - `fn resolvedPath(Allocator, Io, path) ![]u8`, the node to write for a
///   device at `path`, allocated.
/// - `fn unmountDiskAt(Allocator, Io, path) !void`, which unmounts every
///   volume on the disk holding `path`.
pub fn Backend(comptime Platform: type) type {
    return struct {
        pub fn probeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !device.TargetInfo {
            var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false }) catch {
                return regular_file.probeTarget(allocator, io, path);
            };
            defer file.close(io);

            const stat = try file.stat(io);
            const kind: device.TargetKind = switch (stat.kind) {
                .file => return regular_file.probeTarget(allocator, io, path),
                .block_device => .block_device,
                .character_device => if (Platform.accepts_character_devices) .character_device else return error.UnsupportedTargetType,
                else => return error.UnsupportedTargetType,
            };

            const geometry = Platform.geometry(file.handle) orelse return error.UnsupportedTargetType;
            const resolved_path = try Platform.resolvedPath(allocator, io, path);
            errdefer allocator.free(resolved_path);

            return .{
                .requested_path = path,
                .resolved_path = resolved_path,
                .capabilities = .{
                    .kind = kind,
                    .size = geometry.size,
                    .read_alignment = geometry.block_size,
                    .write_alignment = geometry.block_size,
                    .optimal_io_size = 1024 * 1024,
                    .access_pattern = .positional,
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

        pub fn prepareTargetPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
            const info = try probeTarget(allocator, io, path);
            defer info.deinit(allocator);
            if (!info.capabilities.isDevice()) return;
            try Platform.unmountDiskAt(allocator, io, info.resolved_path);
        }

        pub fn prepareTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget) !void {
            if (!target.info.capabilities.isDevice()) return;
            try Platform.unmountDiskAt(allocator, io, target.info.resolved_path);
        }
    };
}
