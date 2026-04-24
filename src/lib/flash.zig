const std = @import("std");

const device = @import("device.zig");
const root = @import("../root.zig");

pub const ByteRange = root.ByteRange;

pub const VerifyMode = enum {
    none,
    written,
};

pub const Phase = enum {
    flash,
    verify,
};

pub const Progress = struct {
    phase: Phase,
    completed_bytes: u64,
    total_bytes: u64,
};

pub const ProgressHandler = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, progress: Progress) anyerror!void,
};

pub const UnsupportedPolicy = enum {
    fail,
};

pub const Options = struct {
    block_size: usize = 1024 * 1024,
    verify: VerifyMode = .written,
    unsupported: UnsupportedPolicy = .fail,
    progress_handler: ?ProgressHandler = null,
    prepare_target: bool = true,
};

pub const Report = struct {
    image_size: u64,
    bytes_read: u64,
    bytes_written: u64,
    bytes_skipped: u64,
    range_count: usize,
};

pub const Plan = struct {
    image_size: u64,
    ranges: []ByteRange,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
    }
};

pub fn flashPlannedImage(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, options: Options) !Report {
    const plan = try root.planImageFlashFromPath(allocator, io, image_path);
    defer plan.deinit(allocator);
    return flashToPathFromPath(allocator, io, image_path, destination_path, plan.image_size, plan.ranges, options);
}

pub fn flashToPathFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, image_size: u64, ranges: []const ByteRange, options: Options) !Report {
    var source = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer source.close(io);

    if (options.prepare_target) {
        try device.prepareTargetPath(allocator, io, destination_path);
    }
    var target = try device.openTarget(allocator, io, destination_path);
    defer target.close(allocator, io);

    return flashToTarget(allocator, io, source, &target, image_size, ranges, options);
}

pub fn flashImage(allocator: std.mem.Allocator, io: std.Io, source: std.Io.File, destination: std.Io.File, image_size: u64, ranges: []const ByteRange, options: Options) !Report {
    const stat = try destination.stat(io);
    const kind: device.TargetKind = switch (stat.kind) {
        .block_device => .block_device,
        .character_device => .character_device,
        else => .regular_file,
    };

    var target = device.OpenTarget{
        .file = destination,
        .info = .{
            .requested_path = "<open-file>",
            .resolved_path = &.{},
            .owns_resolved_path = false,
            .capabilities = .{
                .kind = kind,
                .size = stat.size,
                .read_alignment = if (kind == .regular_file) 1 else 512,
                .write_alignment = if (kind == .regular_file) 1 else 512,
                .optimal_io_size = stat.block_size,
                .access_pattern = if (kind == .regular_file) .positional else .seek_and_stream,
                .supports_verify_reads = true,
            },
        },
    };
    return flashToTarget(allocator, io, source, &target, image_size, ranges, options);
}

fn flashToTarget(allocator: std.mem.Allocator, io: std.Io, source: std.Io.File, target: *device.OpenTarget, image_size: u64, ranges: []const ByteRange, options: Options) !Report {
    if (options.block_size == 0) return error.InvalidBlockSize;

    const destination = &target.file;
    const destination_device = target.info.capabilities.kind != .regular_file;
    const device_block_size: usize = target.info.capabilities.write_alignment;
    const dest_size = target.info.capabilities.size;
    if (dest_size < image_size) return error.DestinationTooSmall;

    const buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(buffer);

    const planned_bytes = countPlannedBytes(ranges);
    if (planned_bytes > 0) {
        try emitProgress(options, .{
            .phase = .flash,
            .completed_bytes = 0,
            .total_bytes = planned_bytes,
        });
    }

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
                try writeAlignedDeviceChunk(allocator, io, source, destination.handle, chunk, offset, device_block_size);
            } else {
                try destination.writePositionalAll(io, chunk, offset);
            }

            remaining -= chunk_len;
            offset += chunk_len;
            bytes_written += chunk_len;
            try emitProgress(options, .{
                .phase = .flash,
                .completed_bytes = bytes_written,
                .total_bytes = planned_bytes,
            });
        }
    }

    try destination.sync(io);
    try maybeVerifyWrittenRanges(allocator, io, source, destination.*, ranges, options, buffer, destination_device, device_block_size, planned_bytes);

    return .{
        .image_size = image_size,
        .bytes_read = bytes_written,
        .bytes_written = bytes_written,
        .bytes_skipped = image_size - bytes_written,
        .range_count = ranges.len,
    };
}

fn countPlannedBytes(ranges: []const ByteRange) u64 {
    var total: u64 = 0;
    for (ranges) |segment| total += segment.length;
    return total;
}

fn emitProgress(options: Options, progress: Progress) !void {
    const handler = options.progress_handler orelse return;
    try handler.callback(handler.context, progress);
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

fn writeAlignedDeviceChunk(allocator: std.mem.Allocator, io: std.Io, source: std.Io.File, fd: std.posix.fd_t, chunk: []const u8, offset: u64, block_size: usize) !void {
    if (chunk.len % block_size == 0) {
        return writeDeviceAll(fd, chunk);
    }

    const aligned_len = std.mem.alignForward(usize, chunk.len, block_size);
    const aligned = try allocator.alloc(u8, aligned_len);
    defer allocator.free(aligned);

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


fn maybeVerifyWrittenRanges(allocator: std.mem.Allocator, io: std.Io, source: std.Io.File, destination: std.Io.File, ranges: []const ByteRange, options: Options, buffer: []u8, destination_device: bool, device_block_size: usize, total_verify_bytes: u64) !void {
    if (options.verify == .none) return;

    var verify_buffer = try allocator.alloc(u8, buffer.len);
    defer allocator.free(verify_buffer);

    if (total_verify_bytes > 0) {
        try emitProgress(options, .{
            .phase = .verify,
            .completed_bytes = 0,
            .total_bytes = total_verify_bytes,
        });
    }

    var bytes_verified: u64 = 0;

    for (ranges) |segment| {
        var remaining = segment.length;
        var offset = segment.offset;

        while (remaining > 0) {
            const chunk_len: usize = @intCast(@min(remaining, buffer.len));
            const source_count = try source.readPositionalAll(io, buffer[0..chunk_len], offset);
            const destination_count = if (destination_device)
                blk: {
                    const aligned_len = std.mem.alignForward(usize, chunk_len, device_block_size);
                    const aligned_verify = try allocator.alloc(u8, aligned_len);
                    defer allocator.free(aligned_verify);

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
            bytes_verified += chunk_len;
            try emitProgress(options, .{
                .phase = .verify,
                .completed_bytes = bytes_verified,
                .total_bytes = total_verify_bytes,
            });
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

    const report = try flashImage(std.testing.allocator, io, source, destination, source_bytes.len, &ranges, .{ .block_size = 2, .verify = .written });
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
    try std.testing.expectError(error.DestinationTooSmall, flashImage(std.testing.allocator, io, source, destination, 4, &ranges, .{}));
}
