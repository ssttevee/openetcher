const builtin = @import("builtin");
const std = @import("std");

const ext4 = @import("fs/ext4.zig");
const image = @import("image.zig");
const range = @import("range.zig");
const types = @import("types.zig");

pub const ByteRange = types.ByteRange;
pub const FlashPlan = types.FlashPlan;
pub const FlashOptions = types.FlashOptions;
pub const FlashReport = types.FlashReport;

pub fn flashExt4Image(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, options: FlashOptions) !FlashReport {
    return flashPlannedImage(allocator, io, image_path, destination_path, options);
}

pub fn flashPlannedImage(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, options: FlashOptions) !FlashReport {
    const plan = try image.planImageFlash(allocator, io, image_path);
    defer plan.deinit(allocator);
    return flashToPath(io, image_path, destination_path, plan.image_size, plan.ranges, options);
}

pub fn flashToPath(io: std.Io, image_path: []const u8, destination_path: []const u8, image_size: u64, ranges: []const ByteRange, options: FlashOptions) !FlashReport {
    var source = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer source.close(io);

    var destination = try std.Io.Dir.cwd().openFile(io, destination_path, .{ .mode = .read_write, .allow_directory = false });
    defer destination.close(io);

    return flashImageWithPath(&source, &destination, io, destination_path, image_size, ranges, options);
}

pub fn flashImage(source: *std.Io.File, destination: *std.Io.File, io: std.Io, image_size: u64, ranges: []const ByteRange, options: FlashOptions) !FlashReport {
    return flashImageWithPath(source, destination, io, null, image_size, ranges, options);
}

fn flashImageWithPath(source: *std.Io.File, destination: *std.Io.File, io: std.Io, destination_path: ?[]const u8, image_size: u64, ranges: []const ByteRange, options: FlashOptions) !FlashReport {
    if (options.block_size == 0) return error.InvalidBlockSize;

    const destination_device = isDeviceFile(destination, io);
    const device_block_size: usize = if (destination_device) 512 else 1;
    const dest_size = try destinationSize(destination, io, destination_path);
    if (dest_size < image_size) return error.DestinationTooSmall;

    const buffer = try std.heap.page_allocator.alloc(u8, options.block_size);
    defer std.heap.page_allocator.free(buffer);

    var bytes_written: u64 = 0;
    for (ranges) |segment| {
        var remaining = segment.length;
        var offset = segment.offset;
        while (remaining > 0) {
            const chunk_len: usize = @intCast(@min(remaining, buffer.len));
            const chunk = buffer[0..chunk_len];
            const read_count = try source.readPositionalAll(io, chunk, offset);
            if (read_count != chunk_len) return error.UnexpectedEndOfImage;
            if (destination_device) {
                try seekDevice(destination.handle, offset);
                try writeAlignedDeviceChunk(source, destination.handle, io, chunk, offset, device_block_size);
            } else {
                try destination.writePositionalAll(io, chunk, offset);
            }

            remaining -= chunk_len;
            offset += chunk_len;
            bytes_written += chunk_len;
        }
    }

    try destination.sync(io);
    try maybeVerifyWrittenRanges(source, destination, io, ranges, options, buffer, destination_device, device_block_size);

    return .{
        .image_size = image_size,
        .bytes_read = bytes_written,
        .bytes_written = bytes_written,
        .bytes_skipped = image_size - bytes_written,
        .range_count = ranges.len,
    };
}

fn destinationSize(destination: *std.Io.File, io: std.Io, destination_path: ?[]const u8) !u64 {
    const stat = destination.stat(io) catch null;
    if (stat) |metadata| {
        if (metadata.kind != .block_device and metadata.kind != .character_device) return metadata.size;
    }

    if (destination_path) |path| {
        if (builtin.os.tag == .macos) {
            if (try macosDiskSize(io, path)) |size| return size;
        }
    }

    return destination.length(io);
}

fn isDeviceFile(file: *std.Io.File, io: std.Io) bool {
    const stat = file.stat(io) catch return false;
    return stat.kind == .block_device or stat.kind == .character_device;
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
        const amt = try std.posix.read(fd, buffer[index..]);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

fn writeAlignedDeviceChunk(source: *std.Io.File, fd: std.posix.fd_t, io: std.Io, chunk: []const u8, offset: u64, block_size: usize) !void {
    if (chunk.len % block_size == 0) {
        return writeDeviceAll(fd, chunk);
    }

    const aligned_len = std.mem.alignForward(usize, chunk.len, block_size);
    const aligned = try std.heap.page_allocator.alloc(u8, aligned_len);
    defer std.heap.page_allocator.free(aligned);

    @memcpy(aligned[0..chunk.len], chunk);
    @memset(aligned[chunk.len..], 0);

    const tail_offset = offset + chunk.len;
    const tail_len = aligned_len - chunk.len;
    const tail_count = try source.readPositionalAll(io, aligned[chunk.len..], tail_offset);
    if (tail_count < tail_len) {
        @memset(aligned[chunk.len + tail_count ..], 0);
    }

    try writeDeviceAll(fd, aligned);
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

fn maybeVerifyWrittenRanges(source: *std.Io.File, destination: *std.Io.File, io: std.Io, ranges: []const ByteRange, options: FlashOptions, buffer: []u8, destination_device: bool, device_block_size: usize) !void {
    if (options.verify == .none) return;

    var verify_buffer = try std.heap.page_allocator.alloc(u8, buffer.len);
    defer std.heap.page_allocator.free(verify_buffer);

    for (ranges) |segment| {
        var remaining = segment.length;
        var offset = segment.offset;

        while (remaining > 0) {
            const chunk_len: usize = @intCast(@min(remaining, buffer.len));
            const source_count = try source.readPositionalAll(io, buffer[0..chunk_len], offset);
            const destination_count = if (destination_device)
                blk: {
                    const aligned_len = std.mem.alignForward(usize, chunk_len, device_block_size);
                    const aligned_verify = try std.heap.page_allocator.alloc(u8, aligned_len);
                    defer std.heap.page_allocator.free(aligned_verify);

                    try seekDevice(destination.handle, offset);
                    const aligned_count = try readDeviceAll(destination.handle, aligned_verify);
                    if (aligned_count < chunk_len) break :blk aligned_count;
                    @memcpy(verify_buffer[0..chunk_len], aligned_verify[0..chunk_len]);
                    break :blk chunk_len;
                }
            else
                try destination.readPositionalAll(io, verify_buffer[0..chunk_len], offset);
            if (source_count != chunk_len or destination_count != chunk_len) return error.VerificationFailed;
            if (!std.mem.eql(u8, buffer[0..chunk_len], verify_buffer[0..chunk_len])) return error.VerificationFailed;

            offset += chunk_len;
            remaining -= chunk_len;
        }
    }
}

test "flashImage copies only declared ranges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = try tmp.dir.createFile(io, "source.img", .{ .read = true });
    defer source.close(io);
    var destination = try tmp.dir.createFile(io, "dest.img", .{ .read = true });
    defer destination.close(io);

    const source_bytes = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0x11, 0x22, 0x33, 0x44 };
    try source.writeStreamingAll(io, &source_bytes);
    try source.sync(io);

    const filler = [_]u8{0} ** source_bytes.len;
    try destination.writeStreamingAll(io, &filler);
    try destination.sync(io);

    const ranges = [_]ByteRange{
        .{ .offset = 0, .length = 2 },
        .{ .offset = 4, .length = 2 },
    };

    const report = try flashImage(&source, &destination, io, source_bytes.len, &ranges, .{ .block_size = 2, .verify = .written });
    try std.testing.expectEqual(@as(u64, 4), report.bytes_written);
    try std.testing.expectEqual(@as(u64, 4), report.bytes_skipped);

    var output: [source_bytes.len]u8 = undefined;
    const read_count = try destination.readPositionalAll(io, &output, 0);
    try std.testing.expectEqual(source_bytes.len, read_count);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0x00, 0x00, 0x11, 0x22, 0x00, 0x00 }, &output);
}

test "flashToPath rejects too-small destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = try tmp.dir.createFile(io, "source.img", .{ .read = true });
    defer source.close(io);
    var destination = try tmp.dir.createFile(io, "dest.img", .{ .read = true });
    defer destination.close(io);

    try source.writeStreamingAll(io, &[_]u8{ 1, 2, 3, 4 });
    try source.sync(io);
    try destination.writeStreamingAll(io, &[_]u8{ 0, 0 });
    try destination.sync(io);

    const ranges = [_]ByteRange{.{ .offset = 0, .length = 4 }};
    try std.testing.expectError(error.DestinationTooSmall, flashImage(&source, &destination, io, 4, &ranges, .{}));
}

test "parseDiskutilSize reads byte count" {
    const sample =
        "   Disk Size:                 63.9 GB (63864569856 Bytes) (exactly 124735488 512-Byte-Units)\n";

    try std.testing.expectEqual(@as(?u64, 63864569856), parseDiskutilSize(sample));
}
