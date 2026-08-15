const std = @import("std");

const device = @import("device.zig");
const root = @import("../root.zig");

pub const ByteRange = root.ByteRange;

pub const VerifyMode = enum {
    none,
    digest,
    reread_source,
    written,
};

pub const Phase = enum {
    probe,
    plan,
    flash,
    verify,
};

pub const Strategy = enum {
    planned_sparse,
    full_if_unsupported,
    force_full_streaming,
};

pub const PrepareOptions = struct {
    max_image_size: ?u64 = null,
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
    verify: VerifyMode = .digest,
    unsupported: UnsupportedPolicy = .fail,
    strategy: Strategy = .planned_sparse,
    max_image_size: ?u64 = null,
    observers: []root.Observer = &.{},
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

pub fn flashSource(allocator: std.mem.Allocator, io: std.Io, source: *root.ImageSource, destination_path: []const u8, options: Options) !Report {
    switch (options.strategy) {
        .planned_sparse => {
            const plan = try root.planImageFlashSource(allocator, io, source, .{ .max_image_size = options.max_image_size });
            defer plan.deinit(allocator);
            return flashPlannedSource(allocator, io, source, destination_path, plan, options);
        },
        .full_if_unsupported => {
            const plan = root.planImageFlashSource(allocator, io, source, .{ .max_image_size = options.max_image_size }) catch |err| switch (err) {
                error.UnsupportedPartitionFilesystem, error.UnsupportedStreamingLayout => null,
                else => return err,
            };
            if (plan) |planned| {
                defer planned.deinit(allocator);
                return flashPlannedSource(allocator, io, source, destination_path, planned, options);
            }
            return flashFullSource(allocator, io, source, destination_path, options);
        },
        .force_full_streaming => return flashFullSource(allocator, io, source, destination_path, options),
    }
}

pub fn flashPlannedSource(allocator: std.mem.Allocator, io: std.Io, image_source: *root.ImageSource, destination_path: []const u8, plan: root.FlashPlan, options: Options) !Report {
    try validatePlan(plan);
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    if (options.max_image_size) |limit| stream.max_image_size = limit;

    var target = try openFlashTarget(allocator, io, destination_path, options);
    defer target.close(allocator, io);
    const result = try flashStream(allocator, io, &stream, &target, plan.image_size, plan.ranges, options);
    if (options.verify == .reread_source or options.verify == .written) {
        var verify_stream = try image_source.openStream(io, allocator);
        defer verify_stream.deinit();
        if (options.max_image_size) |limit| verify_stream.max_image_size = limit;
        try verifySourceRanges(allocator, io, &verify_stream, &target, plan.image_size, plan.ranges, options);
    }
    return result.report;
}

const StreamFlashResult = struct {
    report: Report,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

fn openFlashTarget(allocator: std.mem.Allocator, io: std.Io, destination_path: []const u8, options: Options) !device.OpenTarget {
    if (options.prepare_target) try device.prepareTargetPath(allocator, io, destination_path);
    return device.openTarget(allocator, io, destination_path);
}

fn flashFullSource(allocator: std.mem.Allocator, io: std.Io, image_source: *root.ImageSource, destination_path: []const u8, options: Options) !Report {
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    if (options.max_image_size) |limit| stream.max_image_size = limit;

    var target = try openFlashTarget(allocator, io, destination_path, options);
    defer target.close(allocator, io);
    const result = try flashStream(allocator, io, &stream, &target, image_source.metadata.image_size, null, options);

    if (options.verify == .reread_source or options.verify == .written) {
        var verify_stream = try image_source.openStream(io, allocator);
        defer verify_stream.deinit();
        if (options.max_image_size) |limit| verify_stream.max_image_size = limit;
        const verify_size = result.report.image_size;
        const full_range = [_]ByteRange{.{ .offset = 0, .length = verify_size }};
        try verifySourceRanges(allocator, io, &verify_stream, &target, verify_size, &full_range, options);
    }
    return result.report;
}

fn validatePlan(plan: root.FlashPlan) !void {
    var previous_end: u64 = 0;
    for (plan.ranges, 0..) |item, index| {
        if (item.length == 0) return error.InvalidFlashPlan;
        const end = std.math.add(u64, item.offset, item.length) catch return error.RangeOverflow;
        if (end > plan.image_size) return error.RangeOutsideImage;
        if (index != 0 and item.offset < previous_end) return error.InvalidFlashPlan;
        previous_end = end;
    }
}

fn countRanges(ranges: []const ByteRange) u64 {
    var total: u64 = 0;
    for (ranges) |item| total += item.length;
    return total;
}

fn flashStream(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, expected_size: ?u64, ranges: ?[]const ByteRange, options: Options) !StreamFlashResult {
    if (options.block_size == 0) return error.InvalidBlockSize;
    if (expected_size) |size| {
        if (target.info.capabilities.size < size) return error.DestinationTooSmall;
    }
    if (ranges) |items| {
        const image_size = expected_size orelse return error.InvalidImageSize;
        try validatePlan(.{ .image_size = image_size, .ranges = @constCast(items) });
    }

    const buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const total = if (ranges) |items| countRanges(items) else expected_size orelse 0;
    try emitProgress(options, .{ .phase = .flash, .completed_bytes = 0, .total_bytes = total });

    var logical_size: u64 = 0;
    var bytes_written: u64 = 0;
    if (ranges) |items| {
        for (items) |item| {
            try stream.discardTo(item.offset);
            var remaining = item.length;
            var offset = item.offset;
            while (remaining > 0) {
                const chunk_len: usize = @intCast(@min(remaining, buffer.len));
                const count = try stream.read(buffer[0..chunk_len]);
                if (count == 0) return error.UnexpectedEndOfImage;
                try writeTargetChunk(allocator, io, target, buffer[0..count], offset);
                hasher.update(buffer[0..count]);
                bytes_written += count;
                offset += count;
                logical_size = @max(logical_size, offset);
                remaining -= count;
                try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
            }
        }

        if (expected_size) |size| {
            if (stream.position < size) try stream.discardTo(size);
            if (stream.position != size) return error.ImageSizeMismatch;
            var tail: [1]u8 = undefined;
            if (try stream.read(&tail) != 0) return error.ImageSizeMismatch;
            logical_size = size;
        }
    } else {
        while (true) {
            const count = try stream.read(buffer);
            if (count == 0) break;
            const offset = logical_size;
            const next = std.math.add(u64, logical_size, count) catch return error.DecompressedImageTooLarge;
            if (target.info.capabilities.size < next) return error.DestinationTooSmall;
            try writeTargetChunk(allocator, io, target, buffer[0..count], offset);
            for (options.observers) |*observer| try root.deliverObserver(observer, offset, buffer[0..count]);
            hasher.update(buffer[0..count]);
            logical_size = next;
            bytes_written += count;
            try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
        }
        if (expected_size) |size| if (logical_size != size) return error.ImageSizeMismatch;
        for (options.observers) |*observer| try observer.finish(logical_size);
    }

    try target.file.sync(io);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    if (options.verify == .digest) {
        const verify_range = if (ranges) |items| items else &[_]ByteRange{.{ .offset = 0, .length = logical_size }};
        try verifyDigestTarget(allocator, io, target, verify_range, digest, options);
    }

    return .{
        .report = .{
            .image_size = logical_size,
            .bytes_read = if (ranges != null) logical_size else logical_size,
            .bytes_written = bytes_written,
            .bytes_skipped = logical_size - bytes_written,
            .range_count = if (ranges) |items| items.len else if (logical_size == 0) 0 else 1,
        },
        .digest = digest,
    };
}

fn writeTargetChunk(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, bytes: []const u8, offset: u64) !void {
    if (!target.info.capabilities.isDevice()) {
        try target.file.writePositionalAll(io, bytes, offset);
        return;
    }

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

fn verifyDigestTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, ranges: []const ByteRange, expected: [std.crypto.hash.sha2.Sha256.digest_length]u8, options: Options) !void {
    var buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var completed: u64 = 0;
    const total = countRanges(ranges);
    try emitProgress(options, .{ .phase = .verify, .completed_bytes = 0, .total_bytes = total });
    for (ranges) |item| {
        var remaining = item.length;
        var offset = item.offset;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, buffer.len));
            const actual = if (target.info.capabilities.isDevice())
                try readTargetDeviceChunk(allocator, target, buffer[0..count], offset)
            else
                try target.file.readPositionalAll(io, buffer[0..count], offset);
            if (actual != count) return error.VerificationFailed;
            hasher.update(buffer[0..count]);
            offset += count;
            remaining -= count;
            completed += count;
            try emitProgress(options, .{ .phase = .verify, .completed_bytes = completed, .total_bytes = total });
        }
    }
    var actual_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&actual_digest);
    if (!std.mem.eql(u8, &expected, &actual_digest)) return error.VerificationFailed;
}

fn verifySourceRanges(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, image_size: u64, ranges: []const ByteRange, options: Options) !void {
    try validatePlan(.{ .image_size = image_size, .ranges = @constCast(ranges) });
    const buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(buffer);
    for (ranges) |item| {
        try stream.discardTo(item.offset);
        var remaining = item.length;
        var offset = item.offset;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, buffer.len));
            try stream.readExactly(buffer[0..count]);
            const destination_buffer = try allocator.alloc(u8, count);
            defer allocator.free(destination_buffer);
            const actual = if (target.info.capabilities.isDevice())
                try readTargetDeviceChunk(allocator, target, destination_buffer, offset)
            else
                try target.file.readPositionalAll(io, destination_buffer, offset);
            if (actual != count or !std.mem.eql(u8, buffer[0..count], destination_buffer)) return error.VerificationFailed;
            offset += count;
            remaining -= count;
        }
    }
    if (stream.position < image_size) try stream.discardTo(image_size);
    if (stream.position != image_size) return error.ImageSizeMismatch;
}

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
    var source_digest = std.crypto.hash.sha2.Sha256.init(.{});
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
            source_digest.update(chunk);

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
    var source_digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    source_digest.final(&source_digest_bytes);
    try maybeVerifyWrittenRanges(allocator, io, source, destination.*, ranges, options, buffer, destination_device, device_block_size, planned_bytes, source_digest_bytes);

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

fn readTargetDeviceChunk(allocator: std.mem.Allocator, target: *device.OpenTarget, buffer: []u8, offset: u64) !usize {
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

fn maybeVerifyWrittenRanges(allocator: std.mem.Allocator, io: std.Io, source: std.Io.File, destination: std.Io.File, ranges: []const ByteRange, options: Options, buffer: []u8, destination_device: bool, device_block_size: usize, total_verify_bytes: u64, expected_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8) !void {
    if (options.verify == .none) return;

    if (options.verify == .digest) {
        try emitProgress(options, .{ .phase = .verify, .completed_bytes = 0, .total_bytes = total_verify_bytes });
        var destination_digest = std.crypto.hash.sha2.Sha256.init(.{});
        var verified: u64 = 0;
        for (ranges) |segment| {
            var remaining = segment.length;
            var offset = segment.offset;
            while (remaining > 0) {
                const chunk_len: usize = @intCast(@min(remaining, buffer.len));
                const destination_count = if (destination_device) blk: {
                    var target = device.OpenTarget{
                        .file = destination,
                        .info = .{
                            .requested_path = "<open-file>",
                            .resolved_path = &.{},
                            .owns_resolved_path = false,
                            .capabilities = .{
                                .kind = .character_device,
                                .size = 0,
                                .read_alignment = @intCast(device_block_size),
                                .write_alignment = @intCast(device_block_size),
                                .optimal_io_size = 0,
                                .access_pattern = .seek_and_stream,
                                .supports_verify_reads = true,
                            },
                        },
                    };
                    break :blk try readTargetDeviceChunk(allocator, &target, buffer[0..chunk_len], offset);
                } else try destination.readPositionalAll(io, buffer[0..chunk_len], offset);
                if (destination_count != chunk_len) return error.VerificationFailed;
                destination_digest.update(buffer[0..chunk_len]);
                offset += chunk_len;
                remaining -= chunk_len;
                verified += chunk_len;
                try emitProgress(options, .{ .phase = .verify, .completed_bytes = verified, .total_bytes = total_verify_bytes });
            }
        }
        var destination_digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        destination_digest.final(&destination_digest_bytes);
        if (!std.mem.eql(u8, &expected_digest, &destination_digest_bytes)) return error.VerificationFailed;
        return;
    }

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
            const destination_count = if (destination_device) blk: {
                var target = device.OpenTarget{
                    .file = destination,
                    .info = .{
                        .requested_path = "<open-file>",
                        .resolved_path = &.{},
                        .owns_resolved_path = false,
                        .capabilities = .{
                            .kind = .character_device,
                            .size = 0,
                            .read_alignment = @intCast(device_block_size),
                            .write_alignment = @intCast(device_block_size),
                            .optimal_io_size = 0,
                            .access_pattern = .seek_and_stream,
                            .supports_verify_reads = true,
                        },
                    },
                };
                break :blk try readTargetDeviceChunk(allocator, &target, verify_buffer[0..chunk_len], offset);
            } else try destination.readPositionalAll(io, verify_buffer[0..chunk_len], offset);
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

test "device verification reads unaligned logical ranges through aligned buffers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "device.img", .{ .read = true });
    defer file.close(io);

    var contents: [1024]u8 = undefined;
    for (&contents, 0..) |*byte, index| byte.* = @truncate(index);
    try file.writeStreamingAll(io, &contents);
    try file.sync(io);

    var target = device.OpenTarget{
        .file = file,
        .info = .{
            .requested_path = "<test-device>",
            .resolved_path = &.{},
            .owns_resolved_path = false,
            .capabilities = .{
                .kind = .character_device,
                .size = contents.len,
                .read_alignment = 512,
                .write_alignment = 512,
                .optimal_io_size = 512,
                .access_pattern = .seek_and_stream,
                .supports_verify_reads = true,
            },
        },
    };
    var actual: [513]u8 = undefined;
    const count = try readTargetDeviceChunk(std.testing.allocator, &target, &actual, 3);

    try std.testing.expectEqual(actual.len, count);
    try std.testing.expectEqualSlices(u8, contents[3..][0..actual.len], &actual);
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

const CountedSource = struct {
    bytes: []const u8,
    passes: usize = 0,
};

const CountedStream = struct {
    reader: std.Io.Reader,
    allocator: std.mem.Allocator,

    fn destroy(context: *anyopaque) void {
        const self: *CountedStream = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }
};

fn openCountedStream(context: *anyopaque, _: std.Io, allocator: std.mem.Allocator) !root.Stream {
    const source_context: *CountedSource = @ptrCast(@alignCast(context));
    source_context.passes += 1;
    const stream_context = try allocator.create(CountedStream);
    stream_context.* = .{ .reader = std.Io.Reader.fixed(source_context.bytes), .allocator = allocator };
    return .{ .reader = &stream_context.reader, .context = stream_context, .deinit_fn = CountedStream.destroy };
}

test "source flashing uses replay passes and digest verification" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try std.testing.allocator.alloc(u8, 17 * 2048);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;

    var destination = try tmp.dir.createFile(io, "planned.img", .{ .read = true });
    try destination.writeStreamingAll(io, bytes);
    try destination.sync(io);
    destination.close(io);
    const planned_path = try tmp.dir.realPathFileAlloc(io, "planned.img", std.testing.allocator);
    defer std.testing.allocator.free(planned_path);

    var planned_context = CountedSource{ .bytes = bytes };
    var planned_source = root.ImageSource{
        .context = &planned_context,
        .metadata = .{ .compression = .gzip, .encoded_size = 10, .image_size = null },
        .open_stream_fn = openCountedStream,
    };
    const planned_report = try flashSource(std.testing.allocator, io, &planned_source, planned_path, .{ .verify = .digest });
    try std.testing.expectEqual(@as(usize, 2), planned_context.passes);
    try std.testing.expectEqual(@as(u64, bytes.len), planned_report.bytes_written);

    var force_destination = try tmp.dir.createFile(io, "force.img", .{ .read = true });
    try force_destination.writeStreamingAll(io, bytes);
    try force_destination.sync(io);
    force_destination.close(io);
    const force_path = try tmp.dir.realPathFileAlloc(io, "force.img", std.testing.allocator);
    defer std.testing.allocator.free(force_path);

    var force_context = CountedSource{ .bytes = bytes };
    var force_source = root.ImageSource{
        .context = &force_context,
        .metadata = .{ .compression = .gzip, .encoded_size = 10, .image_size = null },
        .open_stream_fn = openCountedStream,
    };
    _ = try flashSource(std.testing.allocator, io, &force_source, force_path, .{ .strategy = .force_full_streaming, .verify = .digest });
    try std.testing.expectEqual(@as(usize, 1), force_context.passes);
}
