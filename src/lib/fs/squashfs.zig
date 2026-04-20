const std = @import("std");

const root = @import("../../root.zig");

pub const ByteRange = root.ByteRange;
pub const PartitionInfo = root.ImageInfo.PartitionInfo;

const squashfs_magic = 0x73717368;
const superblock_size = 96;

const Superblock = struct {
    block_size: u32,
    bytes_used: u64,
};

pub fn probeSquashfsPartition(io: std.Io, file: std.Io.File, start_offset: u64, size: u64) !PartitionInfo {
    const superblock = try readSuperblock(io, file, start_offset, size);

    return .{
        .index = 0,
        .start_offset = start_offset,
        .size = size,
        .partition_type = 0,
        .filesystem = .squashfs,
        .supported = true,
        .block_size = superblock.block_size,
        .used_bytes = superblock.bytes_used,
        .skipped_bytes = size - superblock.bytes_used,
        .range_count = 1,
    };
}

pub fn collectSquashfsRangesInRegion(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) ![]ByteRange {
    const superblock = try readSuperblock(io, file, start_offset, size);
    const ranges = try allocator.alloc(ByteRange, 1);
    ranges[0] = .{
        .offset = start_offset,
        .length = superblock.bytes_used,
    };
    return ranges;
}

fn readSuperblock(io: std.Io, file: std.Io.File, start_offset: u64, size: u64) !Superblock {
    var buffer: [superblock_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, start_offset);
    if (count != buffer.len) return error.InvalidSquashfsSuperblock;

    if (readU32(buffer[0..4]) != squashfs_magic) return error.InvalidSquashfsSuperblock;
    const block_size = readU32(buffer[12..16]);
    const bytes_used = readU64(buffer[40..48]);

    if (block_size == 0 or bytes_used == 0 or bytes_used > size) return error.InvalidSquashfsSuperblock;

    return .{
        .block_size = block_size,
        .bytes_used = bytes_used,
    };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

test "readSuperblock detects squashfs bytes_used" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "sq.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** 4096;
    std.mem.writeInt(u32, bytes[0..4], squashfs_magic, .little);
    std.mem.writeInt(u32, bytes[12..16], 131072, .little);
    std.mem.writeInt(u64, bytes[40..48], 1024, .little);
    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const superblock = try readSuperblock(io, file, 0, bytes.len);
    try std.testing.expectEqual(@as(u32, 131072), superblock.block_size);
    try std.testing.expectEqual(@as(u64, 1024), superblock.bytes_used);
}
