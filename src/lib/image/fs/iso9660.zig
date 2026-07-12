const std = @import("std");

const root = @import("../../../root.zig");

const ImageInfo = root.ImageInfo;
const ByteRange = root.ByteRange;

const logical_block_size: u32 = 2048;
const primary_volume_descriptor_offset: u64 = 16 * logical_block_size;
const volume_descriptor_size: usize = logical_block_size;

pub fn looksLikeIso9660(io: std.Io, file: std.Io.File, image_size: u64) !bool {
    if (image_size < primary_volume_descriptor_offset + 7) return false;

    var descriptor: [7]u8 = undefined;
    const count = try file.readPositionalAll(io, &descriptor, primary_volume_descriptor_offset);
    return count == descriptor.len and
        descriptor[0] == 1 and
        std.mem.eql(u8, descriptor[1..6], "CD001") and
        descriptor[6] == 1;
}

pub fn probeIso9660Image(io: std.Io, file: std.Io.File) !ImageInfo {
    const image_size = try file.length(io);
    if (!try looksLikeIso9660(io, file, image_size)) return error.InvalidIso9660Image;

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
    if (!try looksLikeIso9660(io, file, image_size)) return error.InvalidIso9660Image;

    const ranges = try allocator.alloc(ByteRange, 1);
    ranges[0] = .{ .offset = 0, .length = image_size };
    return ranges;
}

test "looksLikeIso9660 detects a primary volume descriptor" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "image.iso", .{ .read = true });
    defer file.close(io);

    const image_size = primary_volume_descriptor_offset + volume_descriptor_size;
    const bytes = try std.testing.allocator.alloc(u8, image_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[primary_volume_descriptor_offset] = 1;
    @memcpy(bytes[primary_volume_descriptor_offset + 1 ..][0..5], "CD001");
    bytes[primary_volume_descriptor_offset + 6] = 1;
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);

    try std.testing.expect(try looksLikeIso9660(io, file, image_size));
}
