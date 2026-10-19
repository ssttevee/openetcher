const std = @import("std");

const types = @import("../types.zig");
const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const ondisk = @import("../ondisk.zig");

pub const ByteRange = range.ByteRange;
pub const Reader = reader_mod.Reader;

const logical_block_size: u32 = 2048;
const primary_volume_descriptor_offset: u64 = 16 * logical_block_size;
const volume_descriptor_size: usize = logical_block_size;

/// The header every ECMA-119 volume descriptor starts with.
const VolumeDescriptorHeader = extern struct {
    type: u8,
    identifier: [5]u8,
    version: u8,

    comptime {
        ondisk.expectLayout(VolumeDescriptorHeader, 7, .{ .type = 0, .identifier = 1, .version = 6 });
    }
};

const primary_volume_descriptor_type = 1;

/// Reader-core API. All offsets and ranges use reader coordinates.
pub fn detect(io: std.Io, r: *const Reader) bool {
    if (r.size < primary_volume_descriptor_offset + @sizeOf(VolumeDescriptorHeader)) return false;

    const header = ondisk.read(VolumeDescriptorHeader, io, r, primary_volume_descriptor_offset) catch return false;
    return header.type == primary_volume_descriptor_type and
        std.mem.eql(u8, &header.identifier, "CD001") and
        header.version == 1;
}

pub fn probeRegion(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) !types.Info.Probe {
    _ = allocator;
    if (!detect(io, r)) return error.InvalidIso9660Image;

    return .{
        .filesystem = .iso9660,
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

// Filesystem driver contract; see driver.zig.

pub const name = "iso9660";
pub const unrecognized: types.Info.Filesystem = .linux_unknown;
pub const raw_layout: types.Info.Layout = .raw_iso9660;
pub const filesystem: types.Info.Filesystem = .iso9660;

pub fn blockSize(_: std.Io, _: *const Reader) error{}!u32 {
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
