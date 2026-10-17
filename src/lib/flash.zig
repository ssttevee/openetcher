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
                error.UnsupportedPartitionFilesystem => null,
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

fn emitProgress(options: Options, progress: Progress) !void {
    const handler = options.progress_handler orelse return;
    try handler.callback(handler.context, progress);
}

/// The single write engine. `ranges` selects sparse writing; null writes the
/// whole decoded stream sequentially.
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
                try device.target_io.writeAt(allocator, io, target, buffer[0..count], offset);
                for (options.observers) |*observer| try root.deliverObserver(observer, offset, buffer[0..count]);
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
            try device.target_io.writeAt(allocator, io, target, buffer[0..count], offset);
            for (options.observers) |*observer| try root.deliverObserver(observer, offset, buffer[0..count]);
            hasher.update(buffer[0..count]);
            logical_size = next;
            bytes_written += count;
            try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
        }
        if (expected_size) |size| if (logical_size != size) return error.ImageSizeMismatch;
    }

    for (options.observers) |*observer| try observer.finish(logical_size);

    try device.target_io.sync(io, target);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    if (options.verify == .digest) {
        const verify_range = if (ranges) |items| items else &[_]ByteRange{.{ .offset = 0, .length = logical_size }};
        try verifyDigestTarget(allocator, io, target, verify_range, digest, options);
    }

    return .{
        .report = .{
            .image_size = logical_size,
            .bytes_read = logical_size,
            .bytes_written = bytes_written,
            .bytes_skipped = logical_size - bytes_written,
            .range_count = if (ranges) |items| items.len else if (logical_size == 0) 0 else 1,
        },
        .digest = digest,
    };
}

const StreamFlashResult = struct {
    report: Report,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

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
            const actual = try device.target_io.readAt(allocator, io, target, buffer[0..count], offset);
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
            const actual = try device.target_io.readAt(allocator, io, target, destination_buffer, offset);
            if (actual != count or !std.mem.eql(u8, buffer[0..count], destination_buffer)) return error.VerificationFailed;
            offset += count;
            remaining -= count;
        }
    }
    if (stream.position < image_size) try stream.discardTo(image_size);
    if (stream.position != image_size) return error.ImageSizeMismatch;
}

// Public file-handle entry points. Each wraps the open file in a seekable
// stream and routes through the single engine.

pub fn flashPlannedImage(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, options: Options) !Report {
    const plan = try root.planImageFlashFromPath(allocator, io, image_path);
    defer plan.deinit(allocator);
    return flashToPathFromPath(allocator, io, image_path, destination_path, plan.image_size, plan.ranges, options);
}

pub fn flashToPathFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, destination_path: []const u8, image_size: u64, ranges: []const ByteRange, options: Options) !Report {
    var source_file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer source_file.close(io);

    var stream = try openFileStream(io, allocator, source_file);
    defer stream.deinit();
    if (options.max_image_size) |limit| stream.max_image_size = limit;

    var target = try openFlashTarget(allocator, io, destination_path, options);
    defer target.close(allocator, io);

    const result = try flashStream(allocator, io, &stream, &target, image_size, ranges, options);

    if (options.verify == .reread_source or options.verify == .written) {
        var verify_stream = try openFileStream(io, allocator, source_file);
        defer verify_stream.deinit();
        try verifySourceRanges(allocator, io, &verify_stream, &target, image_size, ranges, options);
    }
    return result.report;
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

    var stream = try openFileStream(io, allocator, source);
    defer stream.deinit();

    const result = try flashStream(allocator, io, &stream, &target, image_size, ranges, options);

    if (options.verify == .reread_source or options.verify == .written) {
        var verify_stream = try openFileStream(io, allocator, source);
        defer verify_stream.deinit();
        try verifySourceRanges(allocator, io, &verify_stream, &target, image_size, ranges, options);
    }
    return result.report;
}

/// Wraps an open seekable file as a replayable `root.Stream` with a seek
/// fast-path so gap skipping costs one lseek instead of reads.
const FileStreamContext = struct {
    file_reader: std.Io.File.Reader,
    buffer: []u8,
    allocator: std.mem.Allocator,

    fn destroy(context: *anyopaque) void {
        const self: *FileStreamContext = @ptrCast(@alignCast(context));
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    fn seekTo(context: *anyopaque, position: u64) std.Io.File.Reader.SeekError!void {
        const self: *FileStreamContext = @ptrCast(@alignCast(context));
        try self.file_reader.seekTo(position);
    }
};

fn openFileStream(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !root.Stream {
    const context = try allocator.create(FileStreamContext);
    errdefer allocator.destroy(context);
    const buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(buffer);

    context.* = .{
        .file_reader = std.Io.File.Reader.init(file, io, buffer),
        .buffer = buffer,
        .allocator = allocator,
    };

    return .{
        .reader = &context.file_reader.interface,
        .context = context,
        .deinit_fn = FileStreamContext.destroy,
        .seek_to_fn = FileStreamContext.seekTo,
    };
}

test "aligned device chunk reads go through the platform dispatcher" {
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
    const count = try device.target_io.readAt(std.testing.allocator, io, &target, &actual, 3);

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

    const filler: [source_bytes.len]u8 = @splat(0);
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

test "flashToPathFromPath writes and verifies planned ranges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe } ++ @as([10]u8, @splat(0));
    try tmp.dir.writeFile(io, .{ .sub_path = "src.img", .data = &source_bytes });

    const dest_bytes: [source_bytes.len]u8 = @splat(0);
    try tmp.dir.writeFile(io, .{ .sub_path = "dst.img", .data = &dest_bytes });

    const src_path = try tmp.dir.realPathFileAlloc(io, "src.img", std.testing.allocator);
    defer std.testing.allocator.free(src_path);
    const dst_path = try tmp.dir.realPathFileAlloc(io, "dst.img", std.testing.allocator);
    defer std.testing.allocator.free(dst_path);

    const ranges = [_]ByteRange{
        .{ .offset = 0, .length = 4 },
        .{ .offset = 10, .length = 6 },
    };

    const report = try flashToPathFromPath(std.testing.allocator, io, src_path, dst_path, source_bytes.len, &ranges, .{ .block_size = 8, .verify = .written });
    try std.testing.expectEqual(@as(u64, 10), report.bytes_written);
    try std.testing.expectEqual(@as(u64, 6), report.bytes_skipped);

    var written_back: [source_bytes.len]u8 = undefined;
    var dst = try tmp.dir.openFile(io, "dst.img", .{ .mode = .read_only });
    defer dst.close(io);
    _ = try dst.readPositionalAll(io, &written_back, 0);
    try std.testing.expectEqualSlices(u8, source_bytes[0..4], written_back[0..4]);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), written_back[4..10]);
    try std.testing.expectEqualSlices(u8, source_bytes[10..16], written_back[10..16]);
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

test "compressed sources decode once for plan, flash, and source verification" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const source_testing = @import("image/source.zig").testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spool_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(spool_dir);

    const bytes = try source_testing.sparseImage(allocator);
    defer allocator.free(bytes);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;
    const path = try source_testing.writeGzip(allocator, io, tmp.dir, "image.iso.gz", bytes);
    defer allocator.free(path);

    {
        var destination = try tmp.dir.createFile(io, "target.img", .{ .read = true });
        defer destination.close(io);
        try destination.setLength(io, bytes.len);
    }
    const target_path = try tmp.dir.realPathFileAlloc(io, "target.img", allocator);
    defer allocator.free(target_path);

    var image_source = try root.openImageSourceFromPath(allocator, io, path, .{ .spool_dir = spool_dir });
    defer image_source.deinit(allocator);
    const plan = try root.planImageFlashSource(allocator, io, &image_source, .{});
    defer plan.deinit(allocator);

    // Every later pass must replay the spool; decoding again would fail.
    try tmp.dir.deleteFile(io, "image.iso.gz");
    const report = try flashPlannedSource(allocator, io, &image_source, target_path, plan, .{ .verify = .reread_source, .prepare_target = false });
    try std.testing.expectEqual(@as(u64, bytes.len), report.bytes_written);

    const written = try tmp.dir.readFileAlloc(io, "target.img", allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualSlices(u8, bytes, written);
}
