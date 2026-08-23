//! Shared target-I/O backends.
//!
//! `posix_dispatcher` serves regular files plus POSIX raw devices with
//! kernel-alignment handling; macOS and Linux use it. A future Windows
//! backend supplies its own dispatcher with Win32 semantics.

const std = @import("std");

const device = @import("../../device.zig");

fn writePositional(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, bytes: []const u8, offset: u64) anyerror!void {
    _ = allocator;
    try target.file.writePositionalAll(io, bytes, offset);
}

fn syncFile(io: std.Io, target: *device.OpenTarget) anyerror!void {
    try target.file.sync(io);
}

/// Reads a possibly unaligned span from a raw device by rounding the request
/// out to alignment boundaries and copying the interior.
pub fn readAlignedDeviceChunk(allocator: std.mem.Allocator, target: *device.OpenTarget, io: std.Io, buffer: []u8, offset: u64) !usize {
    _ = io;
    if (buffer.len == 0) return 0;

    const alignment: usize = @intCast(target.info.capabilities.read_alignment);
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidBlockSize;

    const aligned_offset = std.mem.alignBackward(u64, offset, alignment);
    const prefix: usize = @intCast(offset - aligned_offset);
    const requested_end = std.math.add(usize, prefix, buffer.len) catch return error.OutOfMemory;
    const aligned_len = std.mem.alignForward(usize, requested_end, alignment);
    const allocation_len = std.math.add(usize, aligned_len, alignment - 1) catch return error.OutOfMemory;
    const allocation = try allocator.alloc(u8, allocation_len);
    defer allocator.free(allocation);

    const allocation_address = @intFromPtr(allocation.ptr);
    const aligned_address = std.mem.alignForward(usize, allocation_address, alignment);
    const start = aligned_address - allocation_address;
    const aligned_buffer = allocation[start..][0..aligned_len];

    try seekDevice(target.file.handle, aligned_offset);
    const read_count = try readDeviceAll(target.file.handle, aligned_buffer);
    if (read_count <= prefix) return 0;
    const available = @min(buffer.len, read_count - prefix);
    @memcpy(buffer[0..available], aligned_buffer[prefix..][0..available]);
    return available;
}

/// Writes a possibly unaligned span to a raw device, zero-padding the final
/// partial block so every kernel write lands on an alignment boundary.
pub fn writeAlignedDeviceChunk(allocator: std.mem.Allocator, target: *device.OpenTarget, bytes: []const u8, offset: u64) !void {
    const alignment: usize = @intCast(target.info.capabilities.write_alignment);
    if (alignment == 0) return error.InvalidBlockSize;

    try seekDevice(target.file.handle, offset);
    if (bytes.len % alignment == 0) return writeDeviceAll(target.file.handle, bytes);

    const aligned_len = std.mem.alignForward(usize, bytes.len, alignment);
    const aligned = try allocator.alloc(u8, aligned_len);
    defer allocator.free(aligned);
    @memcpy(aligned[0..bytes.len], bytes);
    @memset(aligned[bytes.len..], 0);
    try writeDeviceAll(target.file.handle, aligned);
}

fn seekDevice(fd: std.posix.fd_t, offset: u64) !void {
    const result = std.posix.system.lseek(fd, @bitCast(@as(i64, @intCast(offset))), std.posix.SEEK.SET);
    switch (std.posix.errno(result)) {
        .SUCCESS => return,
        .INVAL => return error.Unseekable,
        .ACCES => return error.AccessDenied,
        .BADF => return error.NotOpenForWriting,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn writeDeviceAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        const written: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForWriting,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NOSPC => return error.NoSpaceLeft,
            .IO => return error.InputOutput,
            .BUSY => return error.DeviceBusy,
            .FBIG => return error.FileTooBig,
            .DQUOT => return error.DiskQuota,
            else => |err| return std.posix.unexpectedErrno(err),
        };
        if (written == 0) return error.ShortWrite;
        index += written;
    }
}

fn readDeviceAll(fd: std.posix.fd_t, buffer: []u8) !usize {
    var index: usize = 0;
    while (index < buffer.len) {
        const rc = std.posix.system.read(fd, buffer[index..].ptr, buffer.len - index);
        const amt: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading,
            .ACCES => return error.AccessDenied,
            .INVAL => return error.InvalidDeviceRead,
            .IO => return error.InputOutput,
            else => |err| return std.posix.unexpectedErrno(err),
        };
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

const PosixDispatcher = struct {
    fn writeAt(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, bytes: []const u8, offset: u64) anyerror!void {
        if (!target.info.capabilities.isDevice()) return writePositional(allocator, io, target, bytes, offset);
        return writeAlignedDeviceChunk(allocator, target, bytes, offset);
    }

    fn readAt(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, buffer: []u8, offset: u64) anyerror!usize {
        if (!target.info.capabilities.isDevice()) return target.file.readPositionalAll(io, buffer, offset);
        return readAlignedDeviceChunk(allocator, target, io, buffer, offset);
    }

    fn sync(io: std.Io, target: *device.OpenTarget) anyerror!void {
        return syncFile(io, target);
    }
};

const PositionalOnlyDispatcher = struct {
    fn writeAt(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, bytes: []const u8, offset: u64) anyerror!void {
        if (target.info.capabilities.isDevice()) return error.UnsupportedTargetType;
        return writePositional(allocator, io, target, bytes, offset);
    }

    fn readAt(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, buffer: []u8, offset: u64) anyerror!usize {
        _ = allocator;
        if (target.info.capabilities.isDevice()) return error.UnsupportedTargetType;
        return target.file.readPositionalAll(io, buffer, offset);
    }

    fn sync(io: std.Io, target: *device.OpenTarget) anyerror!void {
        return syncFile(io, target);
    }
};

/// Dispatcher used by macOS and Linux: positional I/O for files,
/// alignment-aware raw I/O for devices.
pub const posix_dispatcher: device.TargetIo = .{
    .write_at = PosixDispatcher.writeAt,
    .read_at = PosixDispatcher.readAt,
    .sync = PosixDispatcher.sync,
};

/// Dispatcher used by platforms without raw-device support yet.
pub const positional_only_dispatcher: device.TargetIo = .{
    .write_at = PositionalOnlyDispatcher.writeAt,
    .read_at = PositionalOnlyDispatcher.readAt,
    .sync = PositionalOnlyDispatcher.sync,
};
