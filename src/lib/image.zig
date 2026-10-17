const std = @import("std");

const root = @import("../root.zig");
const source = @import("image/source.zig");
const reader_mod = @import("image/reader.zig");
const fs_api = @import("image/fs.zig");
const layout_api = @import("image/layout.zig");
const mbr = @import("image/layout/mbr.zig");

pub const fs = @import("image/fs.zig");
pub const layout = @import("image/layout.zig");
pub const source_api = source;
pub const compression = @import("image/compression.zig");
pub const region = @import("image/region.zig");
pub const observer = @import("image/observer.zig");
pub const reader = reader_mod;

const range_api = @import("range.zig");
const scan = @import("scan.zig");
const fs_drivers = fs_api.driver;
const layout_drivers = layout_api.driver;

pub const ByteRange = root.ByteRange;
pub const FlashPlan = root.FlashPlan;

pub const ProbeOptions = struct {
    max_image_size: ?u64 = null,
};

pub const PlanOptions = struct {
    max_image_size: ?u64 = null,
};

pub const Info = @import("image/types.zig").Info;
const Layout = Info.Layout;

/// Result of analyzing one whole image through a reader.
///
/// `ranges` is null when a non-empty partition uses an unsupported
/// filesystem; `info.partitions` then carries per-partition reasons.
pub const Analysis = struct {
    info: Info,
    ranges: ?[]ByteRange = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.info.deinit(allocator);
        if (self.ranges) |ranges| allocator.free(ranges);
    }

    /// Moves `info` out without releasing its allocations.
    pub fn takeInfo(self: *@This()) Info {
        const info = self.info;
        self.info = .{ .image_size = 0, .layout = .mbr };
        return info;
    }

    /// Moves `ranges` out without releasing its allocation.
    pub fn takeRanges(self: *@This()) ?[]ByteRange {
        const ranges = self.ranges;
        self.ranges = null;
        return ranges;
    }
};

// Entry points over open files.

pub fn probeImage(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Info {
    const image_size = try file.length(io);
    var region_reader = reader.FileRegion.init(io, file, 0, image_size);
    const r = region_reader.reader();

    var analysis = try analyzeReader(io, allocator, &r);
    defer analysis.deinit(allocator);

    const info = analysis.takeInfo();
    return .{
        .image_size = image_size,
        .encoded_size = image_size,
        .compression = info.compression,
        .layout = info.layout,
        .filesystem = info.filesystem,
        .block_size = info.block_size,
        .used_bytes = info.used_bytes,
        .skipped_bytes = info.skipped_bytes,
        .range_count = info.range_count,
        .partitions = info.partitions,
    };
}

pub fn probeImageFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !Info {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return probeImage(io, allocator, file);
}

pub fn planImageFlash(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !FlashPlan {
    const image_size = try file.length(io);
    var region_reader = reader.FileRegion.init(io, file, 0, image_size);
    const r = region_reader.reader();

    var analysis = try analyzeReader(io, allocator, &r);
    defer analysis.deinit(allocator);

    const ranges = analysis.takeRanges() orelse return error.UnsupportedPartitionFilesystem;
    return .{
        .image_size = image_size,
        .ranges = ranges,
    };
}

pub fn planImageFlashFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !FlashPlan {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return planImageFlash(io, allocator, file);
}

// Entry points over compressed or streamed sources.

pub fn probeImageSource(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, options: ProbeOptions) !Info {
    var analysis = try analyzeSource(allocator, io, image_source, options.max_image_size);
    defer analysis.deinit(allocator);

    const image_size = analysis.info.image_size;
    const info = analysis.takeInfo();
    return .{
        .image_size = image_size,
        .encoded_size = image_source.metadata.encoded_size orelse image_size,
        .compression = image_source.metadata.compression,
        .layout = info.layout,
        .filesystem = info.filesystem,
        .block_size = info.block_size,
        .used_bytes = info.used_bytes,
        .skipped_bytes = info.skipped_bytes,
        .range_count = info.range_count,
        .partitions = info.partitions,
    };
}

pub fn probeImageSourceFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, options: ProbeOptions) !Info {
    var image_source = try source.openImageSourceFromPath(allocator, io, image_path, .{ .max_image_size = options.max_image_size });
    defer image_source.deinit();
    return probeImageSource(allocator, io, &image_source, options);
}

pub fn planImageFlashSourceFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, options: PlanOptions) !FlashPlan {
    var image_source = try source.openImageSourceFromPath(allocator, io, image_path, .{ .max_image_size = options.max_image_size });
    defer image_source.deinit();
    return planImageFlashSource(allocator, io, &image_source, options);
}

pub fn planImageFlashSource(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, options: PlanOptions) !FlashPlan {
    var analysis = try analyzeSource(allocator, io, image_source, options.max_image_size);
    defer analysis.deinit(allocator);

    const ranges = analysis.takeRanges() orelse return error.UnsupportedPartitionFilesystem;
    return .{
        .image_size = analysis.info.image_size,
        .ranges = ranges,
    };
}

/// Analyzes a source through random access, so memory stays proportional
/// to filesystem metadata rather than image size. Compressed sources are
/// decoded into a spool on the first call.
fn analyzeSource(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, max_image_size: ?u64) !Analysis {
    var file_reader = try image_source.openReader(io, max_image_size);
    defer file_reader.close(io);
    const r = file_reader.reader();

    const analysis = try analyzeReader(io, allocator, &r);
    image_source.metadata.image_size = r.size;
    return analysis;
}

/// Analyzes an in-memory image. Useful for tests and callers that already
/// hold the decoded bytes.
pub fn analyzeBytes(io: std.Io, allocator: std.mem.Allocator, bytes: []const u8) !Analysis {
    var buffer_reader = reader.Buffer.init(bytes);
    const r = buffer_reader.reader();
    return analyzeReader(io, allocator, &r);
}

// Core analyzer shared by every entry point.
//
// Detection precedence is deliberate and mirrors the historical pipeline:
//   1. ISO9660 whole-image signature.
//   2. MBR partition table, with per-partition filesystem routing.
//   3. Raw ext4 fallback (its own parser reports precise errors).
// A future raw format inserts one detect-gated branch here, in precedence
// order; a future filesystem or layout registers in its driver.zig instead.
fn analyzeReader(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader) !Analysis {
    if (r.size < mbr.sector_size) return error.InvalidImage;

    if (fs_api.iso9660.detect(io, r)) {
        return analyzeRawFilesystem(fs_api.iso9660, io, allocator, r);
    }

    inline for (layout_drivers.drivers) |L| {
        if (L.detect(io, r)) return analyzePartitioned(L, io, allocator, r);
    }

    return analyzeRawFilesystem(fs_api.ext4, io, allocator, r);
}

fn analyzeRawFilesystem(comptime D: type, io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader) !Analysis {
    // `r.size - used_bytes` trusts the driver to return disjoint ranges;
    // a driver bug must trap rather than wrap into a huge skipped count.
    @setRuntimeSafety(true);
    comptime fs_drivers.validate(D);
    const ranges = try D.collectRanges(allocator, io, r);
    errdefer allocator.free(ranges);
    // Drivers parse untrusted metadata; never let their output leave the image.
    try range_api.checkWithin(ranges, r.size);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .info = .{
            .image_size = r.size,
            .encoded_size = r.size,
            .layout = D.raw_layout,
            .filesystem = D.filesystem,
            .block_size = try D.blockSize(io, r),
            .used_bytes = used_bytes,
            .skipped_bytes = r.size - used_bytes,
            .range_count = ranges.len,
            .partitions = &.{},
        },
        .ranges = ranges,
    };
}

fn analyzePartitioned(comptime L: type, io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader) !Analysis {
    comptime layout_drivers.validate(L);
    const spans = try L.collectSpans(allocator, io, r);
    defer allocator.free(spans);

    var partitions: std.ArrayList(Info.PartitionInfo) = .empty;
    var partition_failed = false;

    var planned_ranges: std.ArrayList(ByteRange) = .empty;
    defer planned_ranges.deinit(allocator);
    var occupied: std.ArrayList(ByteRange) = .empty;
    defer occupied.deinit(allocator);

    {
        errdefer partitions.deinit(allocator);

        for (spans) |span| {
            try occupied.append(allocator, .{ .offset = span.start_offset, .length = span.size });

            const plan = planPartition(io, allocator, r, span);
            defer if (plan.relative_ranges) |relative| allocator.free(relative);

            if (plan.relative_ranges) |relative| {
                const absolute = try toImageRanges(allocator, relative, span);
                defer allocator.free(absolute);
                try planned_ranges.appendSlice(allocator, absolute);
            } else if (plan.partition.filesystem != .empty) {
                partition_failed = true;
            }

            try partitions.append(allocator, plan.partition);
        }
    }

    var info = Info{
        .image_size = r.size,
        .layout = L.layout,
        .partitions = try partitions.toOwnedSlice(allocator),
    };
    errdefer info.deinit(allocator);

    if (partition_failed) return .{ .info = info };

    try appendGapRanges(allocator, &planned_ranges, occupied.items, r.size);

    const normalized = try root.normalizeRanges(allocator, planned_ranges.items);
    var used_bytes: u64 = 0;
    for (normalized) |item| used_bytes += item.length;

    info.used_bytes = used_bytes;
    info.skipped_bytes = r.size - used_bytes;
    info.range_count = normalized.len;

    return .{ .info = info, .ranges = normalized };
}

/// Converts driver-relative ranges to absolute image ranges inside a span.
fn toImageRanges(allocator: std.mem.Allocator, relative: []const ByteRange, span: mbr.PartitionSpan) ![]ByteRange {
    const absolute = try allocator.alloc(ByteRange, relative.len);
    var completed: usize = 0;
    errdefer allocator.free(absolute[0..completed]);

    for (relative) |item| {
        const relative_end = std.math.add(u64, item.offset, item.length) catch return error.RangeOverflow;
        if (relative_end > span.size) return error.RegionOutOfBounds;
        absolute[completed] = .{
            .offset = try std.math.add(u64, span.start_offset, item.offset),
            .length = item.length,
        };
        completed += 1;
    }
    return absolute;
}

const PartitionPlan = struct {
    partition: Info.PartitionInfo,
    /// Write ranges relative to the partition start; null when unsupported.
    relative_ranges: ?[]ByteRange = null,
};

fn planPartition(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader, span: mbr.PartitionSpan) PartitionPlan {
    var slice = reader.Slice.init(r, span.start_offset, span.size);
    const sr = slice.reader();

    inline for (fs_drivers.drivers) |D| {
        if (fs_drivers.claimsMbrType(D, span.partition_type)) return planWithDriver(D, io, allocator, span, &sr);
    }

    if (span.partition_type == 0x83) {
        if (fs_api.squashfs.detect(io, &sr)) {
            return planWithDriver(fs_api.squashfs, io, allocator, span, &sr);
        }

        if (partitionHeadIsZero(io, &sr)) {
            return .{ .partition = .{
                .index = span.index,
                .start_offset = span.start_offset,
                .size = span.size,
                .partition_type = span.partition_type,
                .filesystem = .empty,
                .supported = false,
                .reason = .empty,
            } };
        }

        return planWithDriver(fs_api.ext4, io, allocator, span, &sr);
    }

    return .{ .partition = .{
        .index = span.index,
        .start_offset = span.start_offset,
        .size = span.size,
        .partition_type = span.partition_type,
        .filesystem = .unknown,
        .supported = false,
        .reason = .unknown_type,
    } };
}

fn planWithDriver(comptime D: type, io: std.Io, allocator: std.mem.Allocator, span: mbr.PartitionSpan, sr: *const reader.Reader) PartitionPlan {
    comptime fs_drivers.validate(D);
    const probe = D.probeRegion(allocator, io, sr) catch |err| {
        return .{ .partition = .{
            .index = span.index,
            .start_offset = span.start_offset,
            .size = span.size,
            .partition_type = span.partition_type,
            .filesystem = D.unrecognized,
            .supported = false,
            .reason = .{ .driver_failed = .{ .driver = D.name, .stage = .probe, .err = err } },
        } };
    };

    const relative_ranges = D.collectRanges(allocator, io, sr) catch |err| {
        return .{ .partition = .{
            .index = span.index,
            .start_offset = span.start_offset,
            .size = span.size,
            .partition_type = span.partition_type,
            .filesystem = probe.filesystem,
            .supported = false,
            .reason = .{ .driver_failed = .{ .driver = D.name, .stage = .range_collection, .err = err } },
        } };
    };

    return .{
        .partition = .probed(probe, span.index, span.start_offset, span.size, span.partition_type),
        .relative_ranges = relative_ranges,
    };
}

fn partitionHeadIsZero(io: std.Io, sr: *const reader.Reader) bool {
    var head: [4096]u8 = undefined;
    const length = @min(sr.size, head.len);
    sr.readExactlyAt(io, head[0..@intCast(length)], 0) catch return false;
    return scan.isZero(head[0..@intCast(length)]);
}

fn appendGapRanges(allocator: std.mem.Allocator, ranges: *std.ArrayList(ByteRange), occupied_ranges: []const ByteRange, image_size: u64) !void {
    const normalized_occupied = try root.normalizeRanges(allocator, occupied_ranges);
    defer allocator.free(normalized_occupied);

    var cursor: u64 = 0;
    for (normalized_occupied) |segment| {
        if (cursor < segment.offset) {
            try ranges.append(allocator, .{ .offset = cursor, .length = segment.offset - cursor });
        }
        cursor = segment.end();
    }
    if (cursor < image_size) {
        try ranges.append(allocator, .{ .offset = cursor, .length = image_size - cursor });
    }
}

test {
    _ = @import("image/fuzz.zig");
    _ = @import("image/ondisk.zig");
}

test "analyzeReader detects mbr partitions through a file region" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes: [8192 * 512]u8 = @splat(0);
    bytes[446 + 4] = 0x06;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    bytes[462 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[462 + 8 ..][0..4], 4096, .little);
    std.mem.writeInt(u32, bytes[462 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);

    const fat_offset = 2048 * 512;
    std.mem.writeInt(u16, bytes[fat_offset + 11 ..][0..2], 512, .little);
    bytes[fat_offset + 13] = 4;
    std.mem.writeInt(u16, bytes[fat_offset + 14 ..][0..2], 1, .little);
    bytes[fat_offset + 16] = 2;
    std.mem.writeInt(u16, bytes[fat_offset + 17 ..][0..2], 512, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 19 ..][0..2], 1024, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 22 ..][0..2], 8, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 510 ..][0..2], 0xAA55, .little);

    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const info = try probeImage(io, std.testing.allocator, file);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(Layout.mbr, info.layout);
    try std.testing.expectEqual(@as(usize, 2), info.partitions.len);
    try std.testing.expectEqual(Info.Filesystem.fat16, info.partitions[0].filesystem);
    try std.testing.expectEqual(true, info.partitions[0].supported);
    try std.testing.expectEqual(Info.Filesystem.empty, info.partitions[1].filesystem);
    try std.testing.expectEqual(false, info.partitions[1].supported);

    const plan = try planImageFlash(io, std.testing.allocator, file);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.ranges.len >= 3);
}

test "analyzeBytes supports ISO9660 images end to end" {
    const io = std.testing.io;
    const image_size = 17 * 2048;
    const bytes = try std.testing.allocator.alloc(u8, image_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;

    var analysis = try analyzeBytes(io, std.testing.allocator, bytes);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(Layout.raw_iso9660, analysis.info.layout);
    try std.testing.expectEqual(@as(?Info.Filesystem, .iso9660), analysis.info.filesystem);
    try std.testing.expectEqual(@as(?u64, image_size), analysis.info.used_bytes);

    try std.testing.expectEqual(@as(usize, 1), analysis.ranges.?.len);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 0, .length = image_size }, analysis.ranges.?[0]);
}

test "raw sources are analyzed without buffering the image" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_size: u64 = 1024 * 1024 * 1024;
    {
        var file = try tmp.dir.createFile(io, "large.iso", .{ .read = true });
        defer file.close(io);
        try file.setLength(io, image_size);
        try file.writePositionalAll(io, &.{ 1, 'C', 'D', '0', '0', '1', 1 }, 16 * 2048);
    }

    const path = try tmp.dir.realPathFileAlloc(io, "large.iso", std.testing.allocator);
    defer std.testing.allocator.free(path);

    // Far smaller than the image: buffering it would fail with OutOfMemory.
    var arena_buffer: [1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const allocator = fixed.allocator();

    var image_source = try source.openImageSourceFromPath(allocator, io, path, .{});
    defer image_source.deinit();

    const plan = try planImageFlashSource(allocator, io, &image_source, .{});
    defer plan.deinit(allocator);
    try std.testing.expectEqual(image_size, plan.image_size);
    try std.testing.expectEqual(@as(?u64, image_size), image_source.metadata.image_size);

    try std.testing.expectError(error.DecompressedImageTooLarge, planImageFlashSource(allocator, io, &image_source, .{ .max_image_size = image_size - 1 }));
}

test "planImageFlash rejects unsupported mbr partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes: [4096 * 512]u8 = @splat(0);
    bytes[446 + 4] = 0x0c;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);
    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const path = try tmp.dir.realPathFileAlloc(io, "disk.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.UnsupportedPartitionFilesystem, planImageFlashFromPath(std.testing.allocator, io, path));
}

test "appendGapRanges preserves non-partition disk gaps" {
    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(std.testing.allocator);

    const occupied = [_]ByteRange{
        .{ .offset = 4096, .length = 2048 },
        .{ .offset = 12288, .length = 4096 },
    };

    try appendGapRanges(std.testing.allocator, &ranges, &occupied, 20480);
    try std.testing.expectEqual(@as(usize, 3), ranges.items.len);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 0, .length = 4096 }, ranges.items[0]);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 6144, .length = 6144 }, ranges.items[1]);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 16384, .length = 4096 }, ranges.items[2]);
}
