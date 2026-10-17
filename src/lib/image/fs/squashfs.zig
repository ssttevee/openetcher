const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");
const ondisk = @import("../ondisk.zig");

pub const ByteRange = range.ByteRange;
pub const PartitionInfo = types.Info.PartitionInfo;
pub const Reader = reader_mod.Reader;

const squashfs_magic = 0x73717368;
const superblock_size = @sizeOf(OnDiskSuperblock);

/// The SquashFS 4.0 superblock.
const OnDiskSuperblock = extern struct {
    magic: u32,
    inode_count: u32,
    modification_time: u32,
    block_size: u32,
    fragment_entry_count: u32,
    compression_id: u16,
    block_log: u16,
    flags: u16,
    id_count: u16,
    version_major: u16,
    version_minor: u16,
    root_inode_ref: u64,
    bytes_used: u64,
    id_table_start: u64,
    xattr_id_table_start: u64,
    inode_table_start: u64,
    directory_table_start: u64,
    fragment_table_start: u64,
    export_table_start: u64,

    comptime {
        ondisk.expectLayout(OnDiskSuperblock, 96, .{ .magic = 0, .block_size = 12, .bytes_used = 40, .export_table_start = 88 });
    }
};

const Superblock = struct {
    block_size: u32,
    bytes_used: u64,
};

/// Reader-core API. All offsets and ranges use reader coordinates.
pub fn detect(io: std.Io, r: *const Reader) bool {
    if (r.size < superblock_size) return false;
    const magic = r.readU32LeAt(io, 0) catch return false;
    return magic == squashfs_magic;
}

pub fn probeRegion(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) !PartitionInfo {
    _ = allocator;
    const superblock = try readSuperblock(io, r);

    return .{
        .index = 0,
        .start_offset = 0,
        .size = r.size,
        .partition_type = 0,
        .filesystem = .squashfs,
        .supported = true,
        .block_size = superblock.block_size,
        .used_bytes = superblock.bytes_used,
        .skipped_bytes = r.size - superblock.bytes_used,
        .range_count = 1,
    };
}

pub fn collectRanges(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) ![]ByteRange {
    const superblock = try readSuperblock(io, r);
    const ranges = try allocator.alloc(ByteRange, 1);
    ranges[0] = .{
        .offset = 0,
        .length = superblock.bytes_used,
    };
    return ranges;
}

// File-handle wrappers kept for library callers.

pub fn probeSquashfsPartition(io: std.Io, file: std.Io.File, start_offset: u64, size: u64) !PartitionInfo {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    var partition = try probeRegion(undefined, io, &r);
    partition.start_offset = start_offset;
    return partition;
}

pub fn collectSquashfsRangesInRegion(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) ![]ByteRange {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    return collectRanges(allocator, io, &r);
}

fn readSuperblock(io: std.Io, r: *const Reader) !Superblock {
    if (r.size < superblock_size) return error.InvalidSquashfsSuperblock;

    const raw = try ondisk.read(OnDiskSuperblock, io, r, 0);
    if (raw.magic != squashfs_magic) return error.InvalidSquashfsSuperblock;
    const block_size = raw.block_size;
    const bytes_used = raw.bytes_used;

    if (block_size == 0 or bytes_used == 0 or bytes_used > r.size) return error.InvalidSquashfsSuperblock;

    return .{
        .block_size = block_size,
        .bytes_used = bytes_used,
    };
}

// Filesystem driver contract; see driver.zig.

pub const name = "squashfs";
pub const unrecognized: types.Info.Filesystem = .squashfs;

test "readSuperblock detects squashfs bytes_used" {
    var bytes: [4096]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], squashfs_magic, .little);
    std.mem.writeInt(u32, bytes[12..16], 131072, .little);
    std.mem.writeInt(u64, bytes[40..48], 1024, .little);

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    const io = std.testing.io;

    try std.testing.expect(detect(io, &r));
    const ranges = try collectRanges(std.testing.allocator, io, &r);
    defer std.testing.allocator.free(ranges);

    try std.testing.expectEqual(@as(u64, 1024), ranges[0].length);
}
