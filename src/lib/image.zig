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

const drivers = fs_api.driver;

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
    const bytes = try readSourcePass(allocator, io, image_source, options.max_image_size);
    defer allocator.free(bytes);

    var analysis = try analyzeBytes(io, allocator, bytes);
    defer analysis.deinit(allocator);

    image_source.metadata.image_size = bytes.len;
    const info = analysis.takeInfo();
    return .{
        .image_size = bytes.len,
        .encoded_size = image_source.metadata.encoded_size orelse bytes.len,
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
    defer image_source.deinit(allocator);
    return probeImageSource(allocator, io, &image_source, options);
}

pub fn planImageFlashSourceFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, options: PlanOptions) !FlashPlan {
    var image_source = try source.openImageSourceFromPath(allocator, io, image_path, .{ .max_image_size = options.max_image_size });
    defer image_source.deinit(allocator);
    return planImageFlashSource(allocator, io, &image_source, options);
}

pub fn planImageFlashSource(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, options: PlanOptions) !FlashPlan {
    const bytes = try readSourcePass(allocator, io, image_source, options.max_image_size);
    defer allocator.free(bytes);

    var analysis = try analyzeBytes(io, allocator, bytes);
    defer analysis.deinit(allocator);

    image_source.metadata.image_size = bytes.len;
    const ranges = analysis.takeRanges() orelse return error.UnsupportedPartitionFilesystem;
    return .{
        .image_size = bytes.len,
        .ranges = ranges,
    };
}

/// Analyzes an in-memory image. Useful for tests and callers that already
/// hold the decoded bytes.
pub fn analyzeBytes(io: std.Io, allocator: std.mem.Allocator, bytes: []const u8) !Analysis {
    var buffer_reader = reader.Buffer.init(bytes);
    const r = buffer_reader.reader();
    return analyzeReader(io, allocator, &r);
}

fn readSourcePass(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, max_image_size: ?u64) ![]u8 {
    var decoded_stream = try image_source.openStream(io, allocator);
    defer decoded_stream.deinit();
    if (max_image_size) |limit| decoded_stream.max_image_size = limit;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try decoded_stream.read(&buffer);
        if (count == 0) break;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}

// Core analyzer shared by every entry point.
//
// Detection precedence is deliberate and mirrors the historical pipeline:
//   1. ISO9660 whole-image signature.
//   2. MBR partition table, with per-partition filesystem routing.
//   3. Raw ext4 fallback (its own parser reports precise errors).
// A future raw format inserts one detect-gated branch here, in precedence
// order; a future filesystem registers in fs/driver.zig instead.
fn analyzeReader(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader) !Analysis {
    if (r.size < mbr.sector_size) return error.InvalidImage;

    const iso9660_driver = &fs_api.iso9660.driver;
    if (iso9660_driver.detect(io, r)) {
        return analyzeRawFilesystem(io, allocator, r, iso9660_driver, .raw_iso9660);
    }

    for (&layout_api.driver.drivers) |*layout_driver| {
        if (!layout_driver.detect(io, r)) continue;
        return analyzePartitioned(io, allocator, r, layout_driver);
    }

    const ext4_driver = &fs_api.ext4.driver;
    return analyzeRawFilesystem(io, allocator, r, ext4_driver, .raw_ext4);
}

fn analyzeRawFilesystem(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader, driver: *const drivers.Driver, layout_tag: Layout) !Analysis {
    const ranges = try driver.collect_ranges(allocator, io, r);
    errdefer allocator.free(ranges);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .info = .{
            .image_size = r.size,
            .encoded_size = r.size,
            .layout = layout_tag,
            .filesystem = driver.filesystem_tag,
            .block_size = if (driver.block_size_fn) |block_size_fn| try block_size_fn(io, r) else null,
            .used_bytes = used_bytes,
            .skipped_bytes = r.size - used_bytes,
            .range_count = ranges.len,
            .partitions = &.{},
        },
        .ranges = ranges,
    };
}

fn looksLikeMbr(io: std.Io, r: *const reader.Reader) !bool {
    var sector: [mbr.sector_size]u8 = undefined;
    r.readExactlyAt(io, &sector, 0) catch return false;
    return mbr.looksLikeMbr(&sector);
}

fn analyzePartitioned(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader, layout_driver: *const layout_api.driver.Driver) !Analysis {
    const spans = try layout_driver.collect_spans(allocator, io, r);
    switch (layout_driver.id) {
        .mbr => return analyzeMbrWithSpans(io, allocator, r, spans),
        .raw_ext4, .raw_iso9660 => {
            // Raw filesystem layouts never route through the partitioned path.
            allocator.free(spans);
            return error.InvalidImage;
        },
    }
}

fn analyzeMbrWithSpans(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader, spans: []mbr.PartitionSpan) !Analysis {
    defer allocator.free(spans);

    var partitions: std.ArrayList(Info.PartitionInfo) = .empty;
    var partition_failed = false;

    var planned_ranges: std.ArrayList(ByteRange) = .empty;
    defer planned_ranges.deinit(allocator);
    var occupied: std.ArrayList(ByteRange) = .empty;
    defer occupied.deinit(allocator);

    {
        errdefer {
            for (partitions.items) |partition| if (partition.reason) |reason| allocator.free(reason);
            partitions.deinit(allocator);
        }

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
        .layout = .mbr,
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
    if (drivers.findByMbrType(span.partition_type)) |driver| {
        return planWithDriver(io, allocator, r, span, driver);
    }

    if (span.partition_type == 0x83) {
        var slice = reader.Slice.init(r, span.start_offset, span.size);
        const sr = slice.reader();

        if (fs_api.squashfs.detect(io, &sr)) {
            return planWithDriverReader(io, allocator, span, &fs_api.squashfs.driver, &sr);
        }

        if (partitionHeadIsZero(io, &sr)) {
            return .{ .partition = .{
                .index = span.index,
                .start_offset = span.start_offset,
                .size = span.size,
                .partition_type = span.partition_type,
                .filesystem = .empty,
                .supported = false,
                .reason = allocator.dupe(u8, "partition appears empty") catch null,
            } };
        }

        return planWithDriverReader(io, allocator, span, &fs_api.ext4.driver, &sr);
    }

    return .{ .partition = .{
        .index = span.index,
        .start_offset = span.start_offset,
        .size = span.size,
        .partition_type = span.partition_type,
        .filesystem = .unknown,
        .supported = false,
        .reason = allocator.dupe(u8, "unknown partition type") catch null,
    } };
}

fn planWithDriver(io: std.Io, allocator: std.mem.Allocator, r: *const reader.Reader, span: mbr.PartitionSpan, driver: *const drivers.Driver) PartitionPlan {
    var slice = reader.Slice.init(r, span.start_offset, span.size);
    const sr = slice.reader();
    return planWithDriverReader(io, allocator, span, driver, &sr);
}

fn planWithDriverReader(io: std.Io, allocator: std.mem.Allocator, span: mbr.PartitionSpan, driver: *const drivers.Driver, sr: *const reader.Reader) PartitionPlan {
    const partition = driver.probe_region(allocator, io, sr) catch |err| {
        const label = driverReasonLabel(driver);
        return .{ .partition = .{
            .index = span.index,
            .start_offset = span.start_offset,
            .size = span.size,
            .partition_type = span.partition_type,
            .filesystem = driverFallbackTag(driver),
            .supported = false,
            .reason = std.fmt.allocPrint(allocator, "{s}: {t}", .{ label, err }) catch null,
        } };
    };

    const relative_ranges = driver.collect_ranges(allocator, io, sr) catch |err| {
        return .{ .partition = .{
            .index = span.index,
            .start_offset = span.start_offset,
            .size = span.size,
            .partition_type = span.partition_type,
            .filesystem = partition.filesystem,
            .supported = false,
            .reason = std.fmt.allocPrint(allocator, "{s} range collection failed: {t}", .{ driverReasonLabel(driver), err }) catch null,
        } };
    };

    var filled = partition;
    filled.index = span.index;
    filled.start_offset = span.start_offset;
    filled.size = span.size;
    filled.partition_type = span.partition_type;
    return .{ .partition = filled, .relative_ranges = relative_ranges };
}

fn driverReasonLabel(driver: *const drivers.Driver) []const u8 {
    if (driver == &fs_api.fat.driver) return "fat probe failed";
    if (driver == &fs_api.squashfs.driver) return "squashfs probe failed";
    if (driver == &fs_api.ext4.driver) return "ext4 probe failed";
    if (driver == &fs_api.iso9660.driver) return "iso9660 probe failed";
    return "probe failed";
}

fn driverFallbackTag(driver: *const drivers.Driver) Info.Filesystem {
    if (driver == &fs_api.squashfs.driver) return .squashfs;
    return .linux_unknown;
}

fn partitionHeadIsZero(io: std.Io, sr: *const reader.Reader) bool {
    var head: [4096]u8 = undefined;
    const length = @min(sr.size, head.len);
    sr.readExactlyAt(io, head[0..@intCast(length)], 0) catch return false;
    for (head[0..@intCast(length)]) |byte| {
        if (byte != 0) return false;
    }
    return true;
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
