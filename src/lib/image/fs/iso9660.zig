const std = @import("std");

const types = @import("../types.zig");
const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const driver_api = @import("driver.zig");

pub const ImageInfo = types.Info;
pub const ByteRange = range.ByteRange;
pub const Reader = reader_mod.Reader;

const logical_block_size: u32 = 2048;
const primary_volume_descriptor_offset: u64 = 16 * logical_block_size;
const volume_descriptor_size: usize = logical_block_size;

/// Reader-core API. All offsets and ranges use reader coordinates.
pub fn detect(io: std.Io, r: *const Reader) bool {
    if (r.size < primary_volume_descriptor_offset + 7) return false;

    var descriptor: [7]u8 = undefined;
    r.readExactlyAt(io, &descriptor, primary_volume_descriptor_offset) catch return false;
    return descriptor[0] == 1 and
        std.mem.eql(u8, descriptor[1..6], "CD001") and
        descriptor[6] == 1;
}

pub fn probeRegion(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) anyerror!ImageInfo.PartitionInfo {
    _ = allocator;
    if (!detect(io, r)) return error.InvalidIso9660Image;

    return .{
        .index = 0,
        .start_offset = 0,
        .size = r.size,
        .partition_type = 0,
        .filesystem = .iso9660,
        .supported = true,
        .block_size = logical_block_size,
        .used_bytes = r.size,
        .skipped_bytes = 0,
        .range_count = 1,
    };
}

pub fn collectRanges(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) ![]ByteRange {
    if (!detect(io, r)) return error.InvalidIso9660Image;

    const ranges = try allocator.alloc(ByteRange, 1);
    ranges[0] = .{ .offset = 0, .length = r.size };
    return ranges;
}

// File-handle wrappers kept for library callers.

pub fn looksLikeIso9660(io: std.Io, file: std.Io.File, image_size: u64) !bool {
    var region = reader_mod.FileRegion.init(io, file, 0, image_size);
    const r = region.reader();
    return detect(io, &r);
}

pub fn probeIso9660Image(io: std.Io, file: std.Io.File) !ImageInfo {
    const image_size = try file.length(io);
    var region = reader_mod.FileRegion.init(io, file, 0, image_size);
    const r = region.reader();
    if (!detect(io, &r)) return error.InvalidIso9660Image;

    return .{
        .image_size = image_size,
        .layout = .raw_iso9660,
        .filesystem = .iso9660,
        .block_size = logical_block_size,
        .used_bytes = image_size,
        .skipped_bytes = 0,
        .range_count = 1,
    };
}

pub fn collectIso9660Ranges(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]ByteRange {
    const image_size = try file.length(io);
    var region = reader_mod.FileRegion.init(io, file, 0, image_size);
    const r = region.reader();
    return collectRanges(allocator, io, &r);
}

pub const driver: driver_api.Driver = .{
    .detect = detect,
    .probe_region = probeRegion,
    .collect_ranges = collectRanges,
    .raw_layout = .raw_iso9660,
    .filesystem_tag = .iso9660,
    .block_size_fn = blockSize,
};

fn blockSize(io: std.Io, r: *const Reader) anyerror!u32 {
    _ = io;
    _ = r;
    return logical_block_size;
}

test "detect finds a primary volume descriptor through a buffer reader" {
    const image_size = primary_volume_descriptor_offset + volume_descriptor_size;
    const bytes = try std.testing.allocator.alloc(u8, image_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[primary_volume_descriptor_offset] = 1;
    @memcpy(bytes[primary_volume_descriptor_offset + 1 ..][0..5], "CD001");
    bytes[primary_volume_descriptor_offset + 6] = 1;

    var source = reader_mod.Buffer.init(bytes);
    const r = source.reader();

    try std.testing.expect(detect(std.testing.io, &r));

    const ranges = try collectRanges(std.testing.allocator, std.testing.io, &r);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(u64, image_size), ranges[0].length);
}
