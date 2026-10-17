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

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Two buffers passed back and forth between the caller, which fills one,
/// and an `io.async` task that consumes the other, so producing the next
/// chunk overlaps consuming the last. At most one consume is in flight, so
/// consumers run in submission order and may keep state without locking.
fn Pipeline(comptime Consumer: type) type {
    const Result = @typeInfo(@TypeOf(Consumer.consume)).@"fn".return_type.?;

    return struct {
        consumer: *Consumer,
        slots: [2][]u8,
        next: u1 = 0,
        pending: ?std.Io.Future(Result) = null,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, consumer: *Consumer, slot_len: usize) !Self {
            const first = try allocator.alloc(u8, slot_len);
            errdefer allocator.free(first);
            return .{ .consumer = consumer, .slots = .{ first, try allocator.alloc(u8, slot_len) } };
        }

        /// Cancels any consume still in flight before freeing its buffer.
        fn deinit(self: *Self, allocator: std.mem.Allocator, io: std.Io) void {
            if (self.pending) |*future| _ = future.cancel(io) catch {};
            for (self.slots) |slot| allocator.free(slot);
        }

        /// The buffer to fill next. It is never the one being consumed.
        fn buffer(self: *const Self) []u8 {
            return self.slots[self.next];
        }

        /// Hands `buffer()[0..len]` to the consumer, first waiting for the
        /// previous consume so its errors surface in order.
        fn submit(self: *Self, io: std.Io, len: usize, offset: u64) !void {
            try self.wait(io);
            self.pending = io.async(Consumer.consume, .{ self.consumer, io, self.slots[self.next], len, offset });
            self.next ^= 1;
        }

        /// Waits for the consume in flight, if any.
        fn wait(self: *Self, io: std.Io) !void {
            var future = self.pending orelse return;
            self.pending = null;
            try future.await(io);
        }
    };
}

/// Pipeline consumer for flashing: writes each chunk and folds it into the
/// image digest, off the thread that reads and decodes the source.
const TargetWriter = struct {
    target: *device.OpenTarget,
    hasher: Sha256 = .init(.{}),

    fn consume(self: *TargetWriter, io: std.Io, buffer: []u8, len: usize, offset: u64) !void {
        // Hash first: device writes zero-pad `buffer` past `len` in place.
        self.hasher.update(buffer[0..len]);
        try device.target_io.writeAt(io, self.target, buffer, len, offset);
    }
};

/// Pipeline consumer for digest verification: hashes chunks read back from
/// the target while the next chunk is being read.
const DigestHasher = struct {
    hasher: Sha256 = .init(.{}),

    fn consume(self: *DigestHasher, io: std.Io, buffer: []u8, len: usize, offset: u64) error{}!void {
        _ = io;
        _ = offset;
        self.hasher.update(buffer[0..len]);
    }
};

/// The single write engine. `ranges` selects sparse writing; null writes the
/// whole decoded stream sequentially.
///
/// Reading and decoding the source overlaps hashing and writing the previous
/// chunk. All buffers are allocated up front, so the per-chunk path does not
/// touch `allocator`.
fn flashStream(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, expected_size: ?u64, ranges: ?[]const ByteRange, options: Options) !StreamFlashResult {
    if (options.block_size == 0) return error.InvalidBlockSize;
    if (expected_size) |size| {
        if (target.info.capabilities.size < size) return error.DestinationTooSmall;
    }
    if (ranges) |items| {
        const image_size = expected_size orelse return error.InvalidImageSize;
        try validatePlan(.{ .image_size = image_size, .ranges = @constCast(items) });
    }

    var writer: TargetWriter = .{ .target = target };
    var pipeline: Pipeline(TargetWriter) = try .init(allocator, &writer, try target.info.capabilities.writeBufferLength(options.block_size));
    defer pipeline.deinit(allocator, io);

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
                const chunk = pipeline.buffer()[0..@intCast(@min(remaining, options.block_size))];
                const count = try stream.read(chunk);
                if (count == 0) return error.UnexpectedEndOfImage;
                for (options.observers) |*observer| try root.deliverObserver(observer, offset, chunk[0..count]);
                try pipeline.submit(io, count, offset);
                // `submit` waited for every earlier chunk, so those are written.
                try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
                bytes_written += count;
                offset += count;
                logical_size = @max(logical_size, offset);
                remaining -= count;
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
            const chunk = pipeline.buffer()[0..options.block_size];
            const count = try stream.read(chunk);
            if (count == 0) break;
            const offset = logical_size;
            const next = std.math.add(u64, logical_size, count) catch return error.DecompressedImageTooLarge;
            if (target.info.capabilities.size < next) return error.DestinationTooSmall;
            for (options.observers) |*observer| try root.deliverObserver(observer, offset, chunk[0..count]);
            try pipeline.submit(io, count, offset);
            try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
            logical_size = next;
            bytes_written += count;
        }
        if (expected_size) |size| if (logical_size != size) return error.ImageSizeMismatch;
    }

    try pipeline.wait(io);
    try emitProgress(options, .{ .phase = .flash, .completed_bytes = bytes_written, .total_bytes = total });
    for (options.observers) |*observer| try observer.finish(logical_size);

    try device.target_io.sync(io, target);
    var digest: [Sha256.digest_length]u8 = undefined;
    writer.hasher.final(&digest);
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
    digest: [Sha256.digest_length]u8,
};

/// Reads the written ranges back and compares their digest, overlapping
/// each read with hashing the previous chunk.
fn verifyDigestTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, ranges: []const ByteRange, expected: [Sha256.digest_length]u8, options: Options) !void {
    var digest_hasher: DigestHasher = .{};
    var pipeline: Pipeline(DigestHasher) = try .init(allocator, &digest_hasher, options.block_size);
    defer pipeline.deinit(allocator, io);
    const scratch = try allocator.alloc(u8, try target.info.capabilities.readScratchLength(options.block_size));
    defer allocator.free(scratch);

    var completed: u64 = 0;
    const total = countRanges(ranges);
    try emitProgress(options, .{ .phase = .verify, .completed_bytes = 0, .total_bytes = total });
    for (ranges) |item| {
        var remaining = item.length;
        var offset = item.offset;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, options.block_size));
            const actual = try device.target_io.readAt(io, target, pipeline.buffer()[0..count], offset, scratch);
            if (actual != count) return error.VerificationFailed;
            try pipeline.submit(io, count, offset);
            offset += count;
            remaining -= count;
            completed += count;
            try emitProgress(options, .{ .phase = .verify, .completed_bytes = completed, .total_bytes = total });
        }
    }
    try pipeline.wait(io);
    var actual_digest: [Sha256.digest_length]u8 = undefined;
    digest_hasher.hasher.final(&actual_digest);
    if (!std.mem.eql(u8, &expected, &actual_digest)) return error.VerificationFailed;
}

fn verifySourceRanges(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, image_size: u64, ranges: []const ByteRange, options: Options) !void {
    try validatePlan(.{ .image_size = image_size, .ranges = @constCast(ranges) });
    const source_buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(source_buffer);
    const target_buffer = try allocator.alloc(u8, options.block_size);
    defer allocator.free(target_buffer);
    const scratch = try allocator.alloc(u8, try target.info.capabilities.readScratchLength(options.block_size));
    defer allocator.free(scratch);

    for (ranges) |item| {
        try stream.discardTo(item.offset);
        var remaining = item.length;
        var offset = item.offset;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, options.block_size));
            try stream.readExactly(source_buffer[0..count]);
            const actual = try device.target_io.readAt(io, target, target_buffer[0..count], offset, scratch);
            if (actual != count or !std.mem.eql(u8, source_buffer[0..count], target_buffer[0..count])) return error.VerificationFailed;
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
    var scratch: [513 + 3 * 512]u8 = undefined;
    const count = try device.target_io.readAt(io, &target, &actual, 3, &scratch);

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

/// Opens `file` as if it were a raw device with 512-byte alignment, so tests
/// exercise the aligned device paths without real hardware.
fn testDeviceTarget(io: std.Io, file: std.Io.File) !device.OpenTarget {
    return .{
        .file = file,
        .info = .{
            .requested_path = "<test-device>",
            .resolved_path = &.{},
            .owns_resolved_path = false,
            .capabilities = .{
                .kind = .character_device,
                .size = try file.length(io),
                .read_alignment = 512,
                .write_alignment = 512,
                .optimal_io_size = 512,
                .access_pattern = .seek_and_stream,
                .supports_verify_reads = true,
            },
        },
    };
}

/// Flashes `image` to a fresh device-posing file and returns what the
/// allocator saw. Chunks of 1000 bytes leave every write unaligned.
fn flashToTestDevice(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, image: []const u8, ranges: []const ByteRange) ![]u8 {
    try dir.writeFile(io, .{ .sub_path = "image.img", .data = image });
    var source = try dir.openFile(io, "image.img", .{});
    defer source.close(io);
    var destination = try dir.createFile(io, "device.img", .{ .read = true, .truncate = true });
    defer destination.close(io);
    try destination.setLength(io, image.len + 4096);

    var target = try testDeviceTarget(io, destination);
    var stream = try openFileStream(io, allocator, source);
    defer stream.deinit();
    _ = try flashStream(allocator, io, &stream, &target, image.len, ranges, .{ .block_size = 1000, .verify = .digest });
    return dir.readFileAlloc(io, "device.img", std.testing.allocator, .unlimited);
}

test "pipelined device writes pad unaligned chunks and verify" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var image: [20 * 1024]u8 = undefined;
    for (&image, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);
    const ranges = [_]ByteRange{
        .{ .offset = 0, .length = 5000 },
        .{ .offset = 8192, .length = 3000 },
        .{ .offset = 16384, .length = 4096 },
    };

    const written = try flashToTestDevice(std.testing.allocator, io, tmp.dir, &image, &ranges);
    defer std.testing.allocator.free(written);
    for (ranges) |item| {
        try std.testing.expectEqualSlices(u8, image[item.offset..][0..item.length], written[item.offset..][0..item.length]);
    }
    // Skipped space keeps its contents apart from the tail padding.
    try std.testing.expect(std.mem.allEqual(u8, written[5120..8192], 0));
}

test "flash allocations do not grow with chunk or range count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var image: [64 * 1024]u8 = undefined;
    for (&image, 0..) |*byte, index| byte.* = @truncate(index);

    var counts: [2]usize = undefined;
    const plans = [2][]const ByteRange{
        &.{.{ .offset = 0, .length = 1024 }},
        &.{ .{ .offset = 0, .length = 20 * 1024 }, .{ .offset = 32 * 1024, .length = 4096 }, .{ .offset = 40 * 1024, .length = 24 * 1024 } },
    };
    for (plans, &counts) |ranges, *count| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const written = try flashToTestDevice(failing.allocator(), io, tmp.dir, &image, ranges);
        std.testing.allocator.free(written);
        count.* = failing.allocations;
    }
    // 1 chunk versus 49 chunks over 3 ranges: same setup, nothing per chunk.
    try std.testing.expectEqual(counts[0], counts[1]);
}
