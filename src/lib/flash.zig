const std = @import("std");

const device = @import("device.zig");
const progress_units = @import("progress.zig");
const root = @import("../root.zig");

pub const ByteRange = root.ByteRange;

pub const VerifyMode = enum {
    none,
    digest,
    reread_source,
    written,
};

pub const Strategy = enum {
    planned_sparse,
    full_if_unsupported,
    force_full_streaming,
};

pub const PrepareOptions = struct {
    max_image_size: ?u64 = null,
};

pub const UnsupportedPolicy = enum {
    fail,
};

pub const Options = struct {
    block_size: usize = 1024 * 1024,
    /// Chunks in flight at once. Each is hashed, and when flashing written,
    /// on tasks of its own while the next is read, so a deeper pipeline
    /// keeps more transfers queued at the target. Each costs one
    /// `block_size` buffer; 0 behaves as 1.
    pipeline_depth: usize = 4,
    verify: VerifyMode = .digest,
    unsupported: UnsupportedPolicy = .fail,
    strategy: Strategy = .planned_sparse,
    max_image_size: ?u64 = null,
    observers: []root.Observer = &.{},
    /// Parent of the "KiB written" and "KiB verified" nodes, counted in
    /// KiB (see `progress.zig`). Updates are lock-free atomic stores, and
    /// nothing about progress can fail, so a broken display never aborts a
    /// half-written disk.
    progress: std.Progress.Node = .none,
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

/// SHA-256 rather than BLAKE3: on Apple silicon, with SHA-2 instructions,
/// it hashes about 1.5 times faster per core than `std.crypto.hash.Blake3`.
const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;
const WriteResult = @typeInfo(@TypeOf(device.target_io.writeAt)).@"fn".return_type.?;

/// Every buffer starts on this boundary, which satisfies the memory
/// alignment any raw device asks of positional transfers.
const buffer_alignment: std.mem.Alignment = .fromByteUnits(4096);

/// A ring of chunk buffers cycled between the caller, which fills them in
/// order, and concurrent consumers: every submitted chunk is hashed on one
/// task and, when flashing, written on another. Writes are positional, so
/// with one slot per `Options.pipeline_depth` that many chunks are hashed and
/// written at once while the caller reads the next.
///
/// The digest is a SHA-256 over the chunks' SHA-256 digests, folded in as
/// slots are reclaimed, which happens in submission order. Chunk digests are
/// independent, so hashing spreads across cores instead of serializing the
/// whole pipeline behind one SHA-256 stream. Flashing and verification cut
/// identical chunks from identical ranges, so their digests compare.
const Pipeline = struct {
    memory: []align(buffer_alignment.toByteUnits()) u8,
    slots: []Slot,
    next: usize = 0,
    /// Null when only hashing, as digest verification does.
    target: ?*device.OpenTarget,
    digest: Sha256 = .init(.{}),
    /// Bytes of reclaimed chunks: hashed and, when flashing, written.
    completed: u64 = 0,

    const Slot = struct {
        buffer: []u8,
        len: usize = 0,
        chunk_digest: Digest = undefined,
        hashing: ?std.Io.Future(void) = null,
        writing: ?std.Io.Future(WriteResult) = null,
    };

    fn init(allocator: std.mem.Allocator, depth: usize, slot_len: usize, target: ?*device.OpenTarget) !Pipeline {
        const slots = try allocator.alloc(Slot, @max(depth, 1));
        errdefer allocator.free(slots);
        const stride = buffer_alignment.forward(slot_len);
        const memory = try allocator.alignedAlloc(u8, buffer_alignment, try std.math.mul(usize, slots.len, stride));
        for (slots, 0..) |*slot, index| slot.* = .{ .buffer = memory[index * stride ..][0..slot_len] };
        return .{ .memory = memory, .slots = slots, .target = target };
    }

    /// Cancels and awaits every task still in flight, so none can touch a
    /// buffer after it is freed.
    fn deinit(self: *Pipeline, allocator: std.mem.Allocator, io: std.Io) void {
        for (self.slots) |*slot| {
            if (slot.hashing) |*future| future.cancel(io);
            if (slot.writing) |*future| future.cancel(io) catch {};
        }
        allocator.free(self.memory);
        allocator.free(self.slots);
        self.* = undefined;
    }

    /// The buffer to fill next, once the chunk it last carried is done.
    fn buffer(self: *Pipeline, io: std.Io) ![]u8 {
        const slot = &self.slots[self.next];
        try self.reclaim(io, slot);
        return slot.buffer;
    }

    /// Hands the first `len` bytes of `buffer()` to the consumers.
    fn submit(self: *Pipeline, io: std.Io, len: usize, offset: u64) void {
        const slot = &self.slots[self.next];
        slot.len = len;
        // Writes zero-pad past `len` in place while the hash reads only up
        // to it, so the two tasks never touch the same bytes.
        slot.hashing = start(io, hashChunk, .{ slot.buffer[0..len], &slot.chunk_digest });
        if (self.target) |target| slot.writing = start(io, device.target_io.writeAt, .{ io, target, slot.buffer, len, offset });
        self.next = (self.next + 1) % self.slots.len;
    }

    /// Waits for every chunk in submission order and returns the digest. A
    /// failed write surfaces here or from `buffer`, in submission order.
    fn finish(self: *Pipeline, io: std.Io) !Digest {
        for (0..self.slots.len) |_| {
            try self.reclaim(io, &self.slots[self.next]);
            self.next = (self.next + 1) % self.slots.len;
        }
        return self.digest.finalResult();
    }

    fn reclaim(self: *Pipeline, io: std.Io, slot: *Slot) !void {
        if (slot.hashing) |*future| {
            future.await(io);
            slot.hashing = null;
            self.digest.update(&slot.chunk_digest);
        }
        if (slot.writing) |pending| {
            // Cleared first: a failed chunk has been awaited and must not be
            // canceled again by `deinit`.
            var future = pending;
            slot.writing = null;
            try future.await(io);
        }
        self.completed += slot.len;
        slot.len = 0;
    }

    fn hashChunk(bytes: []const u8, digest: *Digest) void {
        Sha256.hash(bytes, digest, .{});
    }
};

/// Starts `function` on a task of its own, which `io.concurrent` guarantees
/// overlaps the caller. An `Io` that cannot supply one, such as a
/// single-threaded build or one at its concurrency limit, gets `io.async`
/// instead, which may finish `function` before returning: the flash still
/// completes, just without the overlap.
fn start(io: std.Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    return io.concurrent(function, args) catch |err| switch (err) {
        error.ConcurrencyUnavailable => io.async(function, args),
    };
}

/// The single write engine. `ranges` selects sparse writing; null writes the
/// whole decoded stream sequentially.
fn flashStream(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, expected_size: ?u64, ranges: ?[]const ByteRange, options: Options) !StreamFlashResult {
    const capabilities = target.info.capabilities;
    const chunk_len = try capabilities.chunkLength(options.block_size);
    if (expected_size) |size| {
        if (capabilities.size < size) return error.DestinationTooSmall;
    }
    if (ranges) |items| {
        const image_size = expected_size orelse return error.InvalidImageSize;
        try validatePlan(.{ .image_size = image_size, .ranges = @constCast(items) });
        // Chunks start at range offsets, so this check before the first
        // write keeps a plan the device would reject from half-writing it.
        for (items) |item| if (!capabilities.isWriteAligned(item.offset)) return error.UnalignedTargetOffset;
    }

    const result = try writeStream(allocator, io, stream, target, expected_size, ranges, chunk_len, options);
    if (options.verify == .digest) {
        const verify_range = if (ranges) |items| items else &[_]ByteRange{.{ .offset = 0, .length = result.report.image_size }};
        try verifyDigestTarget(allocator, io, target, verify_range, chunk_len, result.digest, options);
    }
    return result;
}

/// Streams the source through a `Pipeline` into `target`, then syncs it.
///
/// Reading and decoding overlaps hashing and writing earlier chunks. All
/// buffers are allocated up front, so the per-chunk path does not touch
/// `allocator`. On failure, including cancelation, every task in flight is
/// canceled and awaited before the buffers are freed, and the target is
/// still synced so whatever reached it is durable.
fn writeStream(allocator: std.mem.Allocator, io: std.Io, stream: *root.Stream, target: *device.OpenTarget, expected_size: ?u64, ranges: ?[]const ByteRange, chunk_len: usize, options: Options) !StreamFlashResult {
    // Declared first so it runs after `pipeline.deinit` has stopped writes.
    errdefer syncAfterFailure(io, target);
    var pipeline: Pipeline = try .init(allocator, options.pipeline_depth, try target.info.capabilities.writeBufferLength(chunk_len), target);
    defer pipeline.deinit(allocator, io);

    const total = if (ranges) |items| countRanges(items) else expected_size orelse 0;
    const progress = options.progress.start("KiB written", progress_units.fromBytes(total));
    defer progress.end();

    var logical_size: u64 = 0;
    var bytes_written: u64 = 0;

    if (ranges) |items| {
        for (items) |item| {
            try stream.discardTo(item.offset);
            var remaining = item.length;
            var offset = item.offset;
            while (remaining > 0) {
                const count: usize = @intCast(@min(remaining, chunk_len));
                const chunk = (try pipeline.buffer(io))[0..count];
                try stream.readExactly(chunk);
                for (options.observers) |*observer| try root.deliverObserver(observer, offset, chunk);
                pipeline.submit(io, count, offset);
                progress.setCompletedItems(progress_units.fromBytes(pipeline.completed));
                bytes_written += count;
                offset += count;
                remaining -= count;
            }
        }

        // `flashStream` requires `expected_size` with `ranges`.
        const size = expected_size.?;
        if (stream.position < size) try stream.discardTo(size);
        if (stream.position != size) return error.ImageSizeMismatch;
        var tail: [1]u8 = undefined;
        if (try stream.read(&tail) != 0) return error.ImageSizeMismatch;
        logical_size = size;
    } else {
        while (true) {
            const chunk = (try pipeline.buffer(io))[0..chunk_len];
            const count = try readChunk(stream, chunk);
            if (count == 0) break;
            const offset = logical_size;
            const next = std.math.add(u64, logical_size, count) catch return error.DecompressedImageTooLarge;
            if (target.info.capabilities.size < next) return error.DestinationTooSmall;
            for (options.observers) |*observer| try root.deliverObserver(observer, offset, chunk[0..count]);
            pipeline.submit(io, count, offset);
            progress.setCompletedItems(progress_units.fromBytes(pipeline.completed));
            logical_size = next;
            bytes_written += count;
        }
        if (expected_size) |size| if (logical_size != size) return error.ImageSizeMismatch;
    }

    const digest = try pipeline.finish(io);
    progress.setCompletedItems(progress_units.fromBytes(pipeline.completed));
    for (options.observers) |*observer| try observer.finish(logical_size);

    try device.target_io.sync(io, target);
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

/// Fills `buffer` unless the stream ends first, so chunk boundaries depend
/// only on offsets, as the chunked digest requires.
fn readChunk(stream: *root.Stream, buffer: []u8) !usize {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try stream.read(buffer[filled..]);
        if (count == 0) break;
        filled += count;
    }
    return filled;
}

/// Best-effort sync after a failed or canceled write phase. Cancel
/// protection keeps a pending cancelation from skipping it: a canceled flash
/// should still leave what it wrote durable.
fn syncAfterFailure(io: std.Io, target: *device.OpenTarget) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    device.target_io.sync(io, target) catch {};
}

const StreamFlashResult = struct {
    report: Report,
    digest: Digest,
};

/// Reads the written ranges back and compares their digest, overlapping
/// each read with hashing earlier chunks.
fn verifyDigestTarget(allocator: std.mem.Allocator, io: std.Io, target: *device.OpenTarget, ranges: []const ByteRange, chunk_len: usize, expected: Digest, options: Options) !void {
    var pipeline: Pipeline = try .init(allocator, options.pipeline_depth, chunk_len, null);
    defer pipeline.deinit(allocator, io);
    const scratch = try allocator.alloc(u8, try target.info.capabilities.readScratchLength(chunk_len));
    defer allocator.free(scratch);

    const progress = options.progress.start("KiB verified", progress_units.fromBytes(countRanges(ranges)));
    defer progress.end();
    for (ranges) |item| {
        var remaining = item.length;
        var offset = item.offset;
        while (remaining > 0) {
            const count: usize = @intCast(@min(remaining, chunk_len));
            const actual = try device.target_io.readAt(io, target, (try pipeline.buffer(io))[0..count], offset, scratch);
            if (actual != count) return error.VerificationFailed;
            pipeline.submit(io, count, offset);
            offset += count;
            remaining -= count;
            progress.setCompletedItems(progress_units.fromBytes(pipeline.completed));
        }
    }
    const actual_digest = try pipeline.finish(io);
    progress.setCompletedItems(progress_units.fromBytes(pipeline.completed));
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

    var completed: u64 = 0;
    const progress = options.progress.start("KiB verified", progress_units.fromBytes(countRanges(ranges)));
    defer progress.end();
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
            completed += count;
            progress.setCompletedItems(progress_units.fromBytes(completed));
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
                .access_pattern = .positional,
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

/// Streams an open file the caller keeps ownership of, seeking over gaps.
fn openFileStream(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !root.Stream {
    return root.Stream.openFile(allocator, io, file, false);
}

test "aligned device chunk reads go through the platform dispatcher" {
    if (!device.target_io.supports_devices) return error.SkipZigTest;
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
                .access_pattern = .positional,
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

/// An ISO9660 image: the analyzer plans it as one range over the whole image.
fn testIsoImage(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 17 * 2048);
    @memset(bytes, 0);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;
    return bytes;
}

test "planned and full source flashes verify by digest" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testIsoImage(allocator);
    defer allocator.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.iso", .data = bytes });
    const image_path = try tmp.dir.realPathFileAlloc(io, "image.iso", allocator);
    defer allocator.free(image_path);

    for ([_]Strategy{ .planned_sparse, .force_full_streaming }) |strategy| {
        const zeros = try allocator.alloc(u8, bytes.len);
        defer allocator.free(zeros);
        @memset(zeros, 0);
        try tmp.dir.writeFile(io, .{ .sub_path = "target.img", .data = zeros });
        const target_path = try tmp.dir.realPathFileAlloc(io, "target.img", allocator);
        defer allocator.free(target_path);

        var image_source = try root.openImageSourceFromPath(allocator, io, image_path, .{});
        defer image_source.deinit();
        const report = try flashSource(allocator, io, &image_source, target_path, .{ .strategy = strategy, .verify = .digest, .prepare_target = false });
        try std.testing.expectEqual(@as(u64, bytes.len), report.bytes_written);

        const written = try tmp.dir.readFileAlloc(io, "target.img", allocator, .unlimited);
        defer allocator.free(written);
        try std.testing.expectEqualSlices(u8, bytes, written);
    }
}

test "full streaming decodes compressed sources without spooling" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const source_testing = @import("image/source.zig").testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testIsoImage(allocator);
    defer allocator.free(bytes);
    const path = try source_testing.writeGzip(allocator, io, tmp.dir, "image.iso.gz", bytes);
    defer allocator.free(path);
    {
        var destination = try tmp.dir.createFile(io, "target.img", .{});
        defer destination.close(io);
        try destination.setLength(io, bytes.len);
    }
    const target_path = try tmp.dir.realPathFileAlloc(io, "target.img", allocator);
    defer allocator.free(target_path);
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);
    const missing_spool_dir = try std.fs.path.join(allocator, &.{ tmp_path, "missing" });
    defer allocator.free(missing_spool_dir);

    // Planning needs random access and so a spool, which cannot be created.
    var planned_source = try root.openImageSourceFromPath(allocator, io, path, .{ .spool_dir = missing_spool_dir });
    defer planned_source.deinit();
    try std.testing.expectError(error.SpoolDirectoryUnavailable, flashSource(allocator, io, &planned_source, target_path, .{ .prepare_target = false }));

    var streamed_source = try root.openImageSourceFromPath(allocator, io, path, .{ .spool_dir = missing_spool_dir });
    defer streamed_source.deinit();
    const report = try flashSource(allocator, io, &streamed_source, target_path, .{ .strategy = .force_full_streaming, .verify = .digest, .prepare_target = false });
    try std.testing.expectEqual(@as(u64, bytes.len), report.bytes_written);
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
    defer image_source.deinit();
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
    if (!device.target_io.supports_devices) return error.SkipZigTest;
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
                .access_pattern = .positional,
                .supports_verify_reads = true,
            },
        },
    };
}

/// Flashes `image` to a fresh device-posing file and returns what it holds
/// afterwards. Blocks of 1000 bytes round up to 1024-byte chunks, so the
/// last chunk of every range with an unaligned length is padded.
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
    // 1 chunk versus 48 chunks over 3 ranges: same setup, nothing per chunk.
    try std.testing.expectEqual(counts[0], counts[1]);
}

const FaultIo = @import("fault_io.zig");

/// A 64 KiB image of sixteen 4 KiB chunks for the fault tests.
const fault_chunk = 4096;
const fault_image: [16 * fault_chunk]u8 = image: {
    @setEvalBranchQuota(100_000);
    var bytes: [16 * fault_chunk]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    break :image bytes;
};

/// Sets up `fault_image` and an empty target with `std.testing.io`, then
/// flashes it through `io` with digest verification. The target poses as a
/// raw device when `as_device` is set. Returns the report, or the flash
/// error once everything is closed.
fn flashThrough(io: std.Io, dir: std.Io.Dir, as_device: bool, options: Options) !Report {
    const setup_io = std.testing.io;
    const allocator = std.testing.allocator;
    try dir.writeFile(setup_io, .{ .sub_path = "image.img", .data = &fault_image });
    var source = try dir.openFile(setup_io, "image.img", .{});
    defer source.close(setup_io);
    var destination = try dir.createFile(setup_io, "target.img", .{ .read = true, .truncate = true });
    defer destination.close(setup_io);
    try destination.setLength(setup_io, fault_image.len);

    var target: device.OpenTarget = if (as_device) try testDeviceTarget(setup_io, destination) else .{
        .file = destination,
        .info = .{
            .requested_path = "<test-file>",
            .resolved_path = &.{},
            .owns_resolved_path = false,
            .capabilities = .{
                .kind = .regular_file,
                .size = fault_image.len,
                .read_alignment = 1,
                .write_alignment = 1,
                .optimal_io_size = fault_chunk,
                .access_pattern = .positional,
                .supports_verify_reads = true,
            },
        },
    };
    var stream = try openFileStream(io, allocator, source);
    defer stream.deinit();
    const ranges = [_]ByteRange{.{ .offset = 0, .length = fault_image.len }};
    var with_defaults = options;
    with_defaults.block_size = fault_chunk;
    return (try flashStream(allocator, io, &stream, &target, fault_image.len, &ranges, with_defaults)).report;
}

fn expectTargetHoldsImage(dir: std.Io.Dir) !void {
    const written = try dir.readFileAlloc(std.testing.io, "target.img", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, &fault_image, written);
}

test "a failed write cancels writes in flight and reports the failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Chunk 3 hangs, so only cancelation can finish it; chunk 2 fails, and
    // the engine notices when it reclaims that slot for chunk 6.
    var fault_io: FaultIo = .init(std.testing.io, &.{
        .{ .op = .write, .offset = 3 * fault_chunk, .effect = .stall },
        .{ .op = .write, .offset = 2 * fault_chunk, .effect = .input_output },
    });
    try std.testing.expectError(error.InputOutput, flashThrough(fault_io.io(), tmp.dir, false, .{ .pipeline_depth = 4, .verify = .digest }));
    try std.testing.expectEqual(@as(u32, 1), fault_io.canceled.load(.monotonic));
}

test "canceling a flash stops its writes and returns Canceled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .write, .offset = 5 * fault_chunk, .effect = .stall }});
    const io = fault_io.io();

    var flash = try io.concurrent(flashThrough, .{ io, tmp.dir, false, Options{ .verify = .digest } });
    var waited: usize = 0;
    while (fault_io.stalled.load(.monotonic) == 0) : (waited += 1) {
        if (waited == 10_000) {
            _ = flash.cancel(io) catch {};
            return error.TestFlashNeverStalled;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.Canceled, flash.cancel(io));
    try std.testing.expectEqual(@as(u32, 1), fault_io.canceled.load(.monotonic));
}

test "a failed verification read is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .read, .offset = 7 * fault_chunk + 1, .effect = .input_output }});
    try std.testing.expectError(error.InputOutput, flashThrough(fault_io.io(), tmp.dir, false, .{ .verify = .digest }));
    // The write phase completed and synced before verification failed.
    try expectTargetHoldsImage(tmp.dir);
}

test "short writes are resumed, except off a device sector" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .write, .offset = fault_chunk, .effect = .{ .short = 100 } }});
        _ = try flashThrough(fault_io.io(), tmp.dir, false, .{ .verify = .digest });
        try expectTargetHoldsImage(tmp.dir);
    }
    {
        var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .write, .offset = fault_chunk, .effect = .{ .short = 512 } }});
        _ = try flashThrough(fault_io.io(), tmp.dir, true, .{ .verify = .digest });
        try expectTargetHoldsImage(tmp.dir);
    }
    {
        // Resuming mid-sector would need an unaligned device write.
        var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .write, .offset = fault_chunk, .effect = .{ .short = 100 } }});
        try std.testing.expectError(error.ShortWrite, flashThrough(fault_io.io(), tmp.dir, true, .{ .verify = .digest }));
    }
}

test "a write that makes no progress fails instead of spinning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault_io: FaultIo = .init(std.testing.io, &.{.{ .op = .write, .offset = 9 * fault_chunk, .effect = .{ .short = 0 } }});
    try std.testing.expectError(error.ShortWrite, flashThrough(fault_io.io(), tmp.dir, false, .{ .verify = .digest }));
}

test "flashing falls back to serial work without concurrency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault_io: FaultIo = .init(std.testing.io, &.{});
    fault_io.serial = true;
    // Device targets last: platforms without raw-device support skip there.
    for ([_]bool{ false, true }) |as_device| {
        for ([_]usize{ 1, 3 }) |depth| {
            _ = try flashThrough(fault_io.io(), tmp.dir, as_device, .{ .pipeline_depth = depth, .verify = .digest });
            try expectTargetHoldsImage(tmp.dir);
        }
    }
}

test "a range off the device's sector boundary fails before writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "image.img", .data = &fault_image });
    var source = try tmp.dir.openFile(io, "image.img", .{});
    defer source.close(io);
    var destination = try tmp.dir.createFile(io, "target.img", .{ .read = true });
    defer destination.close(io);
    try destination.setLength(io, fault_image.len);

    var target = try testDeviceTarget(io, destination);
    var stream = try openFileStream(io, std.testing.allocator, source);
    defer stream.deinit();
    const ranges = [_]ByteRange{ .{ .offset = 0, .length = 512 }, .{ .offset = 1000, .length = 24 } };
    try std.testing.expectError(error.UnalignedTargetOffset, flashStream(std.testing.allocator, io, &stream, &target, fault_image.len, &ranges, .{}));
    var first: [512]u8 = undefined;
    _ = try destination.readPositionalAll(io, &first, 0);
    try std.testing.expect(std.mem.allEqual(u8, &first, 0));
}
