const std = @import("std");

const root = @import("../../root.zig");

pub const ByteRange = root.ByteRange;
pub const ImageInfo = root.ImageInfo;
pub const PartitionInfo = root.ImageInfo.PartitionInfo;

const superblock_offset: u64 = 1024;
const superblock_size: usize = 1024;
const sector_size: usize = 512;
const ext4_magic: u16 = 0xEF53;

const compat_has_journal: u32 = 0x0004;
const compat_ext_attr: u32 = 0x0008;
const compat_resize_inode: u32 = 0x0010;
const compat_dir_index: u32 = 0x0020;
const compat_sparse_super2: u32 = 0x0200;
const compat_orphan_file: u32 = 0x1000;
const incompat_filetype: u32 = 0x0002;
const incompat_recover: u32 = 0x0004;
const incompat_extents: u32 = 0x0040;
const incompat_sixtyfourbit: u32 = 0x0080;
const incompat_flex_bg: u32 = 0x0200;
const incompat_orphan_file: u32 = 0x1000;
const incompat_checksum_seed: u32 = 0x2000;
const ro_compat_sparse_super: u32 = 0x0001;
const ro_compat_large_file: u32 = 0x0002;
const ro_compat_huge_file: u32 = 0x0008;
const ro_compat_dir_nlink: u32 = 0x0020;
const ro_compat_extra_isize: u32 = 0x0040;
const ro_compat_stable_inodes: u32 = 0x0100;
const ro_compat_metadata_csum: u32 = 0x0400;

const supported_compat: u32 = compat_has_journal | compat_ext_attr | compat_resize_inode | compat_dir_index | compat_sparse_super2 | compat_orphan_file;
const supported_incompat: u32 = incompat_filetype | incompat_recover | incompat_extents | incompat_sixtyfourbit | incompat_flex_bg | incompat_orphan_file | incompat_checksum_seed;
const supported_ro_compat: u32 = ro_compat_sparse_super | ro_compat_large_file | ro_compat_huge_file | ro_compat_dir_nlink | ro_compat_extra_isize | ro_compat_stable_inodes | ro_compat_metadata_csum;

const Superblock = struct {
    blocks_count: u64,
    first_data_block: u32,
    log_block_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    magic: u16,
    state: u16,
    rev_level: u32,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    desc_size: u16,
    inode_size: u16,

    fn blockSize(self: Superblock) !u32 {
        if (self.log_block_size > 6) return error.UnsupportedExt4Feature;
        return @as(u32, 1024) << @intCast(self.log_block_size);
    }

    fn groupCount(self: Superblock) !u64 {
        if (self.blocks_per_group == 0) return error.InvalidExt4Superblock;
        return std.math.divCeil(u64, self.blocks_count - self.first_data_block, self.blocks_per_group);
    }
};

const GroupDescriptor = struct {
    block_bitmap: u64,
    inode_bitmap: u64,
    inode_table: u64,
    free_blocks_count: u32,
    flags: u16,
};

pub fn probeExt4Image(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !ImageInfo {
    const ranges = try collectExt4Ranges(allocator, io, image_path);
    defer allocator.free(ranges);

    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    const image_size = try file.length(io);
    const superblock = try readSuperblock(&file, io, 0);
    const block_size = try superblock.blockSize();

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .image_size = image_size,
        .layout = .raw_ext4,
        .filesystem = .ext4,
        .block_size = block_size,
        .used_bytes = used_bytes,
        .skipped_bytes = image_size - used_bytes,
        .range_count = ranges.len,
    };
}

pub fn collectExt4Ranges(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]ByteRange {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);
    return collectExt4RangesFromFile(allocator, &file, io);
}

pub fn collectExt4RangesInRegion(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, start_offset: u64, size: u64) ![]ByteRange {
    return collectExt4RangesFromFileRegion(allocator, file, io, start_offset, size, true);
}

fn collectExt4RangesFromFile(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io) ![]ByteRange {
    const image_size = try file.length(io);
    try rejectUnsupportedImageLayout(file, io, image_size);
    return collectExt4RangesFromFileRegion(allocator, file, io, 0, image_size, false);
}

pub fn probeExt4Partition(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, start_offset: u64, size: u64) !PartitionInfo {
    const superblock = try readSuperblock(file, io, start_offset);
    try validateSuperblock(superblock, size);

    const ranges = try collectExt4RangesFromFileRegion(allocator, file, io, start_offset, size, true);
    defer allocator.free(ranges);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .index = 0,
        .start_offset = start_offset,
        .size = size,
        .partition_type = 0x83,
        .filesystem = .ext4,
        .supported = true,
        .block_size = try superblock.blockSize(),
        .used_bytes = used_bytes,
        .skipped_bytes = size - used_bytes,
        .range_count = ranges.len,
    };
}

fn collectExt4RangesFromFileRegion(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, start_offset: u64, size: u64, offset_ranges: bool) ![]ByteRange {
    const superblock = try readSuperblock(file, io, start_offset);
    try validateSuperblock(superblock, size);

    const block_size = try superblock.blockSize();
    const blocks_count = superblock.blocks_count;
    const groups_count = try superblock.groupCount();
    const desc_size = descriptorSize(superblock);
    const descriptors_per_block = @max(@as(u64, 1), block_size / desc_size);
    const descriptor_table_blocks = try std.math.divCeil(u64, groups_count * desc_size, block_size);
    const descriptor_table_block: u64 = if (block_size == 1024) 2 else 1;
    const inode_size = inodeSize(superblock);
    const inode_table_blocks = try std.math.divCeil(u64, @as(u64, inode_size) * superblock.inodes_per_group, block_size);

    const descriptors = try allocator.alloc(GroupDescriptor, groups_count);
    defer allocator.free(descriptors);
    try readGroupDescriptors(file, io, superblock, descriptors, descriptor_table_block, desc_size, block_size, start_offset);

    const bitmap_buffer = try allocator.alloc(u8, block_size);
    defer allocator.free(bitmap_buffer);

    var used_blocks: std.ArrayList(ByteRange) = .empty;
    defer used_blocks.deinit(allocator);

    var group_index: u64 = 0;
    while (group_index < groups_count) : (group_index += 1) {
        const descriptor = descriptors[group_index];
        const group_first_block = superblock.first_data_block + (group_index * superblock.blocks_per_group);
        const remaining_blocks = blocks_count - group_first_block;
        const blocks_in_group = @min(@as(u64, superblock.blocks_per_group), remaining_blocks);

        try appendMetadataRanges(allocator, &used_blocks, block_size, group_index, group_first_block, descriptor_table_block, descriptor_table_blocks, descriptors_per_block, descriptor, inode_table_blocks, start_offset, offset_ranges);
        try readBlock(file, io, descriptor.block_bitmap, block_size, bitmap_buffer, start_offset);

        var block_in_group: u64 = 0;
        while (block_in_group < blocks_in_group) : (block_in_group += 1) {
            if (!bitmapBitIsSet(bitmap_buffer, block_in_group)) continue;

            const block_number = group_first_block + block_in_group;
            try used_blocks.append(allocator, .{
                .offset = addImageOffset(block_number * block_size, start_offset, offset_ranges),
                .length = block_size,
            });
        }
    }

    return root.normalizeRanges(allocator, used_blocks.items);
}

fn readSuperblock(file: *std.Io.File, io: std.Io, start_offset: u64) !Superblock {
    var buffer: [superblock_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, start_offset + superblock_offset);
    if (count != buffer.len) return error.InvalidExt4Superblock;

    const magic = readU16(buffer[56..58]);
    if (magic != ext4_magic) return error.InvalidExt4Superblock;

    const blocks_lo = readU32(buffer[4..8]);
    const first_data_block = readU32(buffer[20..24]);
    const log_block_size = readU32(buffer[24..28]);
    const blocks_per_group = readU32(buffer[32..36]);
    const inodes_per_group = readU32(buffer[40..44]);
    const rev_level = readU32(buffer[76..80]);
    const feature_compat = readU32(buffer[92..96]);
    const feature_incompat = readU32(buffer[96..100]);
    const feature_ro_compat = readU32(buffer[100..104]);
    const desc_size = readU16(buffer[254..256]);
    const state = readU16(buffer[58..60]);
    const inode_size = if (rev_level >= 1) readU16(buffer[88..90]) else 128;
    const blocks_hi = if (rev_level >= 1) readU32(buffer[336..340]) else 0;

    return .{
        .blocks_count = (@as(u64, blocks_hi) << 32) | blocks_lo,
        .first_data_block = first_data_block,
        .log_block_size = log_block_size,
        .blocks_per_group = blocks_per_group,
        .inodes_per_group = inodes_per_group,
        .magic = magic,
        .state = state,
        .rev_level = rev_level,
        .feature_compat = feature_compat,
        .feature_incompat = feature_incompat,
        .feature_ro_compat = feature_ro_compat,
        .desc_size = desc_size,
        .inode_size = inode_size,
    };
}

fn rejectUnsupportedImageLayout(file: *std.Io.File, io: std.Io, image_size: u64) !void {
    if (image_size < sector_size) return;

    var sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &sector, 0);
    if (count != sector.len) return error.InvalidExt4Superblock;

    if (!looksLikeMbr(&sector)) return;
    return error.UnsupportedImageLayout;
}

fn looksLikeMbr(sector: *const [sector_size]u8) bool {
    if (readU16(sector[510..512]) != 0xAA55) return false;

    for (0..4) |entry_index| {
        const entry_offset = 446 + (entry_index * 16);
        const entry = sector[entry_offset .. entry_offset + 16];
        const partition_type = entry[4];
        const start_lba = readU32(entry[8..12]);
        const size_lba = readU32(entry[12..16]);
        if (partition_type != 0 and size_lba != 0 and start_lba != 0) return true;
    }

    return false;
}

fn validateSuperblock(superblock: Superblock, image_size: u64) !void {
    if (superblock.magic != ext4_magic) return error.InvalidExt4Superblock;
    if (superblock.blocks_count == 0) return error.InvalidExt4Superblock;
    if (superblock.blocks_per_group == 0) return error.InvalidExt4Superblock;
    if (superblock.inodes_per_group == 0) return error.InvalidExt4Superblock;

    const block_size = try superblock.blockSize();
    const filesystem_size = superblock.blocks_count * block_size;
    if (filesystem_size > image_size) return error.InvalidExt4Superblock;

    if ((superblock.feature_compat & ~supported_compat) != 0) return error.UnsupportedExt4CompatFeature;
    if ((superblock.feature_incompat & ~supported_incompat) != 0) return error.UnsupportedExt4IncompatFeature;
    if ((superblock.feature_ro_compat & ~supported_ro_compat) != 0) return error.UnsupportedExt4ReadOnlyFeature;
}

fn descriptorSize(superblock: Superblock) u64 {
    if ((superblock.feature_incompat & incompat_sixtyfourbit) != 0 and superblock.desc_size >= 32) {
        return superblock.desc_size;
    }
    return 32;
}

fn inodeSize(superblock: Superblock) u16 {
    return if (superblock.inode_size >= 128) superblock.inode_size else 128;
}

fn readGroupDescriptors(file: *std.Io.File, io: std.Io, superblock: Superblock, descriptors: []GroupDescriptor, descriptor_table_block: u64, desc_size: u64, block_size: u32, start_offset: u64) !void {
    var descriptor_buffer = try std.heap.page_allocator.alloc(u8, @intCast(desc_size));
    defer std.heap.page_allocator.free(descriptor_buffer);

    const table_offset = start_offset + (descriptor_table_block * block_size);
    for (descriptors, 0..) |*descriptor, index| {
        const offset = table_offset + (index * desc_size);
        const count = try file.readPositionalAll(io, descriptor_buffer, offset);
        if (count != descriptor_buffer.len) return error.InvalidExt4Superblock;

        const block_bitmap_lo = readU32(descriptor_buffer[0..4]);
        const inode_bitmap_lo = readU32(descriptor_buffer[4..8]);
        const inode_table_lo = readU32(descriptor_buffer[8..12]);
        const free_blocks_lo = readU16(descriptor_buffer[12..14]);
        const flags = readU16(descriptor_buffer[18..20]);
        const block_bitmap_hi = if (desc_size >= 64) readU32(descriptor_buffer[32..36]) else 0;
        const inode_bitmap_hi = if (desc_size >= 64) readU32(descriptor_buffer[36..40]) else 0;
        const inode_table_hi = if (desc_size >= 64) readU32(descriptor_buffer[40..44]) else 0;
        const free_blocks_hi = if (desc_size >= 64) readU16(descriptor_buffer[44..46]) else 0;

        descriptor.* = .{
            .block_bitmap = (@as(u64, block_bitmap_hi) << 32) | block_bitmap_lo,
            .inode_bitmap = (@as(u64, inode_bitmap_hi) << 32) | inode_bitmap_lo,
            .inode_table = (@as(u64, inode_table_hi) << 32) | inode_table_lo,
            .free_blocks_count = (@as(u32, free_blocks_hi) << 16) | free_blocks_lo,
            .flags = flags,
        };
        _ = superblock;
    }
}

fn appendMetadataRanges(allocator: std.mem.Allocator, list: *std.ArrayList(ByteRange), block_size: u32, group_index: u64, group_first_block: u64, descriptor_table_block: u64, descriptor_table_blocks: u64, descriptors_per_block: u64, descriptor: GroupDescriptor, inode_table_blocks: u64, start_offset: u64, offset_ranges: bool) !void {
    _ = descriptors_per_block;

    if (groupIndexHasSuperblock(group_index)) {
        const superblock_block: u64 = if (group_index == 0 and block_size == 1024) 1 else group_first_block;
        try list.append(allocator, .{ .offset = addImageOffset(superblock_block * block_size, start_offset, offset_ranges), .length = block_size });

        const descriptor_block = if (group_index == 0) descriptor_table_block else superblock_block + 1;
        try list.append(allocator, .{ .offset = addImageOffset(descriptor_block * block_size, start_offset, offset_ranges), .length = descriptor_table_blocks * block_size });
    }

    try list.append(allocator, .{ .offset = addImageOffset(descriptor.block_bitmap * block_size, start_offset, offset_ranges), .length = block_size });
    try list.append(allocator, .{ .offset = addImageOffset(descriptor.inode_bitmap * block_size, start_offset, offset_ranges), .length = block_size });
    try list.append(allocator, .{ .offset = addImageOffset(descriptor.inode_table * block_size, start_offset, offset_ranges), .length = inode_table_blocks * block_size });
}

fn readBlock(file: *std.Io.File, io: std.Io, block_number: u64, block_size: u32, buffer: []u8, start_offset: u64) !void {
    if (buffer.len < block_size) return error.InternalBufferTooSmall;
    const count = try file.readPositionalAll(io, buffer[0..block_size], start_offset + (block_number * block_size));
    if (count != block_size) return error.InvalidExt4Superblock;
}

fn addImageOffset(offset: u64, start_offset: u64, offset_ranges: bool) u64 {
    return if (offset_ranges) start_offset + offset else offset;
}

fn bitmapBitIsSet(buffer: []const u8, index: u64) bool {
    const byte_index: usize = @intCast(index / 8);
    const bit_mask: u8 = @as(u8, 1) << @intCast(index % 8);
    return (buffer[byte_index] & bit_mask) != 0;
}

fn groupIndexHasSuperblock(group_index: u64) bool {
    if (group_index <= 1) return true;
    return isPowerOf(group_index, 3) or isPowerOf(group_index, 5) or isPowerOf(group_index, 7);
}

fn isPowerOf(value: u64, base: u64) bool {
    if (value == 0) return false;
    var current = value;
    while (current % base == 0) current /= base;
    return current == 1;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

test "group index sparse super selection" {
    try std.testing.expect(groupIndexHasSuperblock(0));
    try std.testing.expect(groupIndexHasSuperblock(1));
    try std.testing.expect(groupIndexHasSuperblock(3));
    try std.testing.expect(groupIndexHasSuperblock(5));
    try std.testing.expect(groupIndexHasSuperblock(7));
    try std.testing.expect(groupIndexHasSuperblock(9));
    try std.testing.expect(!groupIndexHasSuperblock(2));
    try std.testing.expect(!groupIndexHasSuperblock(11));
}

test "probeExt4Image rejects invalid magic" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "invalid.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** 4096;
    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    try std.testing.expectError(error.InvalidExt4Superblock, collectExt4RangesFromFile(std.testing.allocator, &file, io));
}

test "collectExt4Ranges rejects mbr disk images" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** 4096;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);

    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    try std.testing.expectError(error.UnsupportedImageLayout, collectExt4RangesFromFile(std.testing.allocator, &file, io));
}
