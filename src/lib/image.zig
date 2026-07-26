const std = @import("std");

const root = @import("../root.zig");
const source = @import("image/source.zig");
const scan = @import("image/scan.zig");

pub const fs = @import("image/fs.zig");
pub const layout = @import("image/layout.zig");
pub const source_api = source;
pub const compression = @import("image/compression.zig");
pub const stream = @import("image/stream.zig");
pub const region = @import("image/region.zig");
pub const observer = @import("image/observer.zig");

const mbr = layout.mbr;

pub const ByteRange = root.ByteRange;
pub const FlashPlan = root.FlashPlan;

pub const ProbeOptions = struct {
    max_image_size: ?u64 = null,
};

pub const PlanOptions = struct {
    max_image_size: ?u64 = null,
};

pub const Info = @import("image/types.zig").Info;

const sector_size = mbr.sector_size;

pub fn probeImage(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Info {
    const image_size = try file.length(io);
    var mbr_sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &mbr_sector, 0);
    if (count != mbr_sector.len) return error.InvalidImage;

    if (try fs.iso9660.looksLikeIso9660(io, file, image_size)) {
        var info = try fs.iso9660.probeIso9660Image(io, file);
        info.encoded_size = image_size;
        return info;
    }

    if (!mbr.looksLikeMbr(&mbr_sector)) {
        var info = try fs.ext4.probeExt4Image(io, allocator, file);
        info.encoded_size = image_size;
        return info;
    }

    const partition_spans = try mbr.collectPartitionSpans(allocator, &mbr_sector, image_size);
    defer allocator.free(partition_spans);

    var partitions: std.ArrayList(Info.PartitionInfo) = .empty;
    defer partitions.deinit(allocator);

    for (partition_spans) |partition_span| {
        const partition = classifyPartition(io, allocator, file, partition_span.index, partition_span.partition_type, partition_span.start_offset, partition_span.size);
        try partitions.append(allocator, partition);
    }

    return .{
        .image_size = image_size,
        .encoded_size = image_size,
        .layout = .mbr,
        .partitions = try partitions.toOwnedSlice(allocator),
    };
}

pub fn probeImageFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !Info {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return probeImage(io, allocator, file);
}

pub fn planImageFlash(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !FlashPlan {
    const image_size = try file.length(io);
    var mbr_sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &mbr_sector, 0);
    if (count != mbr_sector.len) return error.InvalidImage;

    if (try fs.iso9660.looksLikeIso9660(io, file, image_size)) {
        return .{
            .image_size = image_size,
            .ranges = try fs.iso9660.collectIso9660Ranges(allocator, io, file),
        };
    }

    if (!mbr.looksLikeMbr(&mbr_sector)) {
        return .{
            .image_size = image_size,
            .ranges = try fs.ext4.collectExt4Ranges(io, allocator, file),
        };
    }

    const partition_spans = try mbr.collectPartitionSpans(allocator, &mbr_sector, image_size);
    defer allocator.free(partition_spans);

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);
    var occupied: std.ArrayList(ByteRange) = .empty;
    defer occupied.deinit(allocator);

    for (partition_spans) |partition_span| {
        try occupied.append(allocator, .{ .offset = partition_span.start_offset, .length = partition_span.size });

        const partition = classifyPartition(io, allocator, file, partition_span.index, partition_span.partition_type, partition_span.start_offset, partition_span.size);
        defer if (partition.reason) |reason| allocator.free(reason);

        if (!partition.supported) {
            if (partition.filesystem == .empty) continue;
            return error.UnsupportedPartitionFilesystem;
        }

        switch (partition.filesystem) {
            .ext4 => {
                const ext4_ranges = try fs.ext4.collectExt4RangesInRegion(io, allocator, file, partition_span.start_offset, partition_span.size);
                defer allocator.free(ext4_ranges);
                try appendRegionRanges(allocator, &ranges, ext4_ranges, partition_span.start_offset, partition_span.size);
            },
            .fat16, .fat32 => {
                const fat_ranges = try fs.fat.collectFatRangesInRegion(io, allocator, file, partition_span.start_offset, partition_span.size);
                defer allocator.free(fat_ranges);
                try appendRegionRanges(allocator, &ranges, fat_ranges, partition_span.start_offset, partition_span.size);
            },
            .squashfs => {
                const squashfs_ranges = try fs.squashfs.collectSquashfsRangesInRegion(io, allocator, file, partition_span.start_offset, partition_span.size);
                defer allocator.free(squashfs_ranges);
                try appendRegionRanges(allocator, &ranges, squashfs_ranges, partition_span.start_offset, partition_span.size);
            },
            else => return error.UnsupportedPartitionFilesystem,
        }
    }

    try appendGapRanges(allocator, &ranges, occupied.items, image_size);

    const normalized_ranges = try root.normalizeRanges(allocator, ranges.items);
    errdefer allocator.free(normalized_ranges);

    return .{
        .image_size = image_size,
        .ranges = normalized_ranges,
    };
}

pub fn planImageFlashFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !FlashPlan {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return planImageFlash(io, allocator, file);
}

pub fn probeImageSource(allocator: std.mem.Allocator, io: std.Io, image_source: *source.ImageSource, options: ProbeOptions) !Info {
    const bytes = try readSourcePass(allocator, io, image_source, options.max_image_size);
    defer allocator.free(bytes);

    var probe = try scan.probe(bytes, allocator);
    defer probe.deinit(allocator);
    image_source.metadata.image_size = bytes.len;
    return infoFromProbe(allocator, probe, image_source.metadata, null, null);
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

    var analysis = try scan.analyze(bytes, allocator);
    defer analysis.deinit(allocator);
    image_source.metadata.image_size = bytes.len;
    const ranges = analysis.ranges orelse return error.InvalidImage;
    analysis.ranges = null;
    return .{
        .image_size = bytes.len,
        .ranges = ranges,
    };
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

fn infoFromProbe(allocator: std.mem.Allocator, probe: scan.Probe, metadata: source.Metadata, used_bytes: ?u64, ranges: ?[]const ByteRange) !Info {
    var partitions: std.ArrayList(Info.PartitionInfo) = .empty;
    errdefer {
        for (partitions.items) |partition| if (partition.reason) |reason| allocator.free(reason);
        partitions.deinit(allocator);
    }

    for (probe.partitions) |partition| {
        try partitions.append(allocator, .{
            .index = partition.index,
            .start_offset = partition.start_offset,
            .size = partition.size,
            .partition_type = partition.partition_type,
            .filesystem = partition.filesystem,
            .supported = partition.supported,
            .reason = if (partition.reason) |reason| try allocator.dupe(u8, reason) else null,
            .block_size = partition.block_size,
            .used_bytes = null,
            .skipped_bytes = null,
            .range_count = null,
        });
    }

    const calculated_used = used_bytes orelse if (ranges) |items| blk: {
        var total: u64 = 0;
        for (items) |item| total = try std.math.add(u64, total, item.length);
        break :blk total;
    } else null;

    return .{
        .image_size = probe.image_size,
        .encoded_size = metadata.encoded_size,
        .compression = metadata.compression,
        .layout = switch (probe.layout) {
            .raw_ext4 => .raw_ext4,
            .raw_iso9660 => .raw_iso9660,
            .mbr => .mbr,
        },
        .filesystem = probe.filesystem,
        .block_size = probe.block_size,
        .used_bytes = calculated_used,
        .skipped_bytes = if (calculated_used) |used| probe.image_size - used else null,
        .range_count = if (ranges) |items| items.len else null,
        .partitions = try partitions.toOwnedSlice(allocator),
    };
}

fn classifyPartition(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, index: u8, partition_type: u8, start_offset: u64, size: u64) Info.PartitionInfo {
    if (partition_type == 0x06 or partition_type == 0x0b or partition_type == 0x0c or partition_type == 0x0e) {
        const probed = fs.fat.probeFatPartition(io, allocator, file, start_offset, size) catch |err| {
            const reason = std.fmt.allocPrint(allocator, "fat probe failed: {t}", .{err}) catch null;
            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = .unknown,
                .supported = false,
                .reason = reason,
            };
        };

        var partition = probed;
        partition.index = index;
        partition.partition_type = partition_type;
        return partition;
    }

    if (partition_type == 0x83) {
        const linux_kind = classifyLinuxPartition(io, file, start_offset) catch .linux_unknown;
        if (linux_kind != .linux_unknown) {
            if (linux_kind == .squashfs) {
                const probed = fs.squashfs.probeSquashfsPartition(io, file, start_offset, size) catch |err| {
                    const reason = std.fmt.allocPrint(allocator, "squashfs probe failed: {t}", .{err}) catch null;
                    return .{
                        .index = index,
                        .start_offset = start_offset,
                        .size = size,
                        .partition_type = partition_type,
                        .filesystem = .squashfs,
                        .supported = false,
                        .reason = reason,
                    };
                };

                var partition = probed;
                partition.index = index;
                partition.partition_type = partition_type;
                return partition;
            }

            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = linux_kind,
                .supported = false,
                .reason = switch (linux_kind) {
                    .empty => allocator.dupe(u8, "partition appears empty") catch null,
                    else => null,
                },
            };
        }

        const probed = fs.ext4.probeExt4Partition(io, allocator, file, start_offset, size) catch |err| {
            const reason = std.fmt.allocPrint(allocator, "ext4 probe failed: {t}", .{err}) catch null;
            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = .linux_unknown,
                .supported = false,
                .reason = reason,
            };
        };

        var partition = probed;
        partition.index = index;
        partition.partition_type = partition_type;
        return partition;
    }

    return .{
        .index = index,
        .start_offset = start_offset,
        .size = size,
        .partition_type = partition_type,
        .filesystem = .unknown,
        .supported = false,
        .reason = allocator.dupe(u8, "unknown partition type") catch null,
    };
}

fn classifyLinuxPartition(io: std.Io, file: std.Io.File, start_offset: u64) !Info.Filesystem {
    var header: [4096]u8 = undefined;
    const count = try file.readPositionalAll(io, &header, start_offset);
    if (count == 0) return .empty;

    if (std.mem.eql(u8, header[0..4], "hsqs")) return .squashfs;
    if (isAllZero(header[0..count])) return .empty;
    return .linux_unknown;
}

fn isAllZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

test "probeImage detects mbr partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** (8192 * 512);
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

    try std.testing.expectEqual(@as(Info.Layout, .mbr), info.layout);
    try std.testing.expectEqual(@as(usize, 2), info.partitions.len);
    try std.testing.expectEqual(@as(Info.Filesystem, .fat16), info.partitions[0].filesystem);
    try std.testing.expectEqual(true, info.partitions[0].supported);
    try std.testing.expectEqual(@as(Info.Filesystem, .empty), info.partitions[1].filesystem);
    try std.testing.expectEqual(false, info.partitions[1].supported);
}

test "probeImage and planImageFlash support ISO9660 images" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "image.iso", .{ .read = true });
    defer file.close(io);

    const image_size = 17 * 2048;
    const bytes = try std.testing.allocator.alloc(u8, image_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);

    const info = try probeImage(io, std.testing.allocator, file);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(Info.Layout.raw_iso9660, info.layout);
    try std.testing.expectEqual(@as(?Info.Filesystem, .iso9660), info.filesystem);
    try std.testing.expectEqual(@as(?u64, image_size), info.used_bytes);

    const plan = try planImageFlash(io, std.testing.allocator, file);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.ranges.len);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 0, .length = image_size }, plan.ranges[0]);
}

test "planImageFlash rejects unsupported mbr partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** (4096 * 512);
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

fn appendRegionRanges(allocator: std.mem.Allocator, ranges: *std.ArrayList(ByteRange), relative_ranges: []const ByteRange, region_offset: u64, region_size: u64) !void {
    for (relative_ranges) |relative| {
        const relative_end = std.math.add(u64, relative.offset, relative.length) catch return error.RangeOverflow;
        if (relative_end > region_size) return error.RegionOutOfBounds;
        try ranges.append(allocator, .{
            .offset = std.math.add(u64, region_offset, relative.offset) catch return error.RangeOverflow,
            .length = relative.length,
        });
    }
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
