const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

pub const ByteRange = range.ByteRange;
pub const ImageInfo = types.Info;
pub const PartitionInfo = types.Info.PartitionInfo;
pub const Reader = reader_mod.Reader;

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

    fn filesystemSize(self: Superblock) !u64 {
        return std.math.mul(u64, self.blocks_count, try self.blockSize());
    }

    fn groupCount(self: Superblock) !u64 {
        if (self.blocks_count < self.first_data_block) return error.InvalidExt4Superblock;
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

/// Reader-core API. All offsets and ranges use reader coordinates.
pub fn detect(io: std.Io, r: *const Reader) bool {
    const magic_offset = superblock_offset + 56;
    if (r.size < magic_offset + 2) return false;
    const magic = r.readU16LeAt(io, magic_offset) catch return false;
    return magic == ext4_magic;
}

/// Reads the block size from the superblock without a full probe.
pub fn superblockBlockSize(io: std.Io, r: *const Reader) !u32 {
    const superblock = try readSuperblock(io, r);
    try validateSuperblock(superblock, r.size);
    return superblock.blockSize();
}

pub fn probeRegion(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) !PartitionInfo {
    const superblock = try readSuperblock(io, r);
    try validateSuperblock(superblock, r.size);

    const ranges = try collectRanges(allocator, io, r);
    defer allocator.free(ranges);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .index = 0,
        .start_offset = 0,
        .size = r.size,
        .partition_type = 0,
        .filesystem = .ext4,
        .supported = true,
        .block_size = try superblock.blockSize(),
        .used_bytes = used_bytes,
        .skipped_bytes = r.size - used_bytes,
        .range_count = ranges.len,
    };
}

pub fn collectRanges(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) ![]ByteRange {
    const superblock = try readSuperblock(io, r);
    try validateSuperblock(superblock, r.size);

    const block_size = try superblock.blockSize();
    const blocks_count = superblock.blocks_count;
    const groups_count = try superblock.groupCount();
    const desc_size = descriptorSize(superblock);
    const descriptor_table_blocks = try std.math.divCeil(u64, try std.math.mul(u64, groups_count, desc_size), block_size);
    const descriptor_table_block: u64 = if (block_size == 1024) 2 else 1;
    const inode_size = inodeSize(superblock);
    const inode_table_blocks = try std.math.divCeil(u64, try std.math.mul(u64, inode_size, superblock.inodes_per_group), block_size);

    const descriptors = try allocator.alloc(GroupDescriptor, @intCast(groups_count));
    defer allocator.free(descriptors);
    try readGroupDescriptors(io, allocator, r, descriptors, descriptor_table_block, desc_size, block_size);

    const bitmap_buffer = try allocator.alloc(u8, block_size);
    defer allocator.free(bitmap_buffer);

    var used_blocks: std.ArrayList(ByteRange) = .empty;
    defer used_blocks.deinit(allocator);

    var group_index: u64 = 0;
    while (group_index < groups_count) : (group_index += 1) {
        const descriptor = descriptors[@intCast(group_index)];
        const group_first_block = superblock.first_data_block + (group_index * superblock.blocks_per_group);
        const remaining_blocks = blocks_count - group_first_block;
        const blocks_in_group = @min(@as(u64, superblock.blocks_per_group), remaining_blocks);

        try checkDescriptor(descriptor, blocks_count, inode_table_blocks);
        try appendMetadataRanges(allocator, &used_blocks, block_size, group_index, group_first_block, descriptor_table_block, descriptor_table_blocks, descriptor, inode_table_blocks);
        try readBlock(io, r, descriptor.block_bitmap, block_size, bitmap_buffer);

        var block_in_group: u64 = 0;
        while (block_in_group < blocks_in_group) : (block_in_group += 1) {
            if (!bitmapBitIsSet(bitmap_buffer, block_in_group)) continue;

            const block_number = group_first_block + block_in_group;
            try used_blocks.append(allocator, .{
                .offset = block_number * block_size,
                .length = block_size,
            });
        }
    }

    return range.normalizeWithin(allocator, used_blocks.items, r.size);
}

// File-handle wrappers kept for library callers.

pub fn probeExt4Image(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !ImageInfo {
    const ranges = try collectExt4Ranges(io, allocator, file);
    defer allocator.free(ranges);

    const image_size = try file.length(io);
    var region = reader_mod.FileRegion.init(io, file, 0, image_size);
    const r = region.reader();
    const block_size = try superblockBlockSize(io, &r);

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

pub fn probeExt4ImageFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !ImageInfo {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return probeExt4Image(io, allocator, file);
}

pub fn collectExt4Ranges(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ![]ByteRange {
    const image_size = try file.length(io);
    try rejectUnsupportedImageLayout(io, file, image_size);

    var region = reader_mod.FileRegion.init(io, file, 0, image_size);
    const r = region.reader();
    return collectRanges(allocator, io, &r);
}

pub fn collectExt4RangesFromPath(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]ByteRange {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return collectExt4Ranges(io, allocator, file);
}

pub fn collectExt4RangesInRegion(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) ![]ByteRange {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    return collectRanges(allocator, io, &r);
}

pub fn probeExt4Partition(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) !PartitionInfo {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    var partition = try probeRegion(allocator, io, &r);
    partition.start_offset = start_offset;
    partition.partition_type = 0x83;
    return partition;
}

fn readSuperblock(io: std.Io, r: *const Reader) !Superblock {
    var buffer: [superblock_size]u8 = undefined;
    try r.readExactlyAt(io, &buffer, superblock_offset);

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

fn rejectUnsupportedImageLayout(io: std.Io, file: std.Io.File, image_size: u64) !void {
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

    const filesystem_size = try superblock.filesystemSize();
    if (filesystem_size > image_size) return error.InvalidExt4Superblock;
    // Each group's block bitmap is one block, so it describes at most
    // block_size * 8 blocks.
    if (superblock.blocks_per_group > @as(u64, try superblock.blockSize()) * 8) return error.InvalidExt4Superblock;

    if ((superblock.feature_compat & ~supported_compat) != 0) return error.UnsupportedExt4CompatFeature;
    if ((superblock.feature_incompat & ~supported_incompat) != 0) return error.UnsupportedExt4IncompatFeature;
    if ((superblock.feature_ro_compat & ~supported_ro_compat) != 0) return error.UnsupportedExt4ReadOnlyFeature;
}

/// Descriptor block numbers are untrusted. Keeping them inside the
/// filesystem also bounds every later `block * block_size` by the image size.
fn checkDescriptor(descriptor: GroupDescriptor, blocks_count: u64, inode_table_blocks: u64) !void {
    if (descriptor.block_bitmap >= blocks_count) return error.InvalidExt4GroupDescriptor;
    if (descriptor.inode_bitmap >= blocks_count) return error.InvalidExt4GroupDescriptor;
    const inode_table_end = std.math.add(u64, descriptor.inode_table, inode_table_blocks) catch return error.InvalidExt4GroupDescriptor;
    if (inode_table_end > blocks_count) return error.InvalidExt4GroupDescriptor;
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

fn readGroupDescriptors(io: std.Io, allocator: std.mem.Allocator, r: *const Reader, descriptors: []GroupDescriptor, descriptor_table_block: u64, desc_size: u64, block_size: u32) !void {
    var descriptor_buffer = try allocator.alloc(u8, @intCast(desc_size));
    defer allocator.free(descriptor_buffer);

    const table_offset = descriptor_table_block * block_size;
    for (descriptors, 0..) |*descriptor, index| {
        const offset = table_offset + (index * desc_size);
        try r.readExactlyAt(io, descriptor_buffer, offset);

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
    }
}

fn appendMetadataRanges(allocator: std.mem.Allocator, list: *std.ArrayList(ByteRange), block_size: u32, group_index: u64, group_first_block: u64, descriptor_table_block: u64, descriptor_table_blocks: u64, descriptor: GroupDescriptor, inode_table_blocks: u64) !void {
    if (groupIndexHasSuperblock(group_index)) {
        const superblock_block: u64 = if (group_index == 0 and block_size == 1024) 1 else group_first_block;
        try list.append(allocator, .{ .offset = superblock_block * block_size, .length = block_size });

        const descriptor_block = if (group_index == 0) descriptor_table_block else superblock_block + 1;
        try list.append(allocator, .{ .offset = descriptor_block * block_size, .length = descriptor_table_blocks * block_size });
    }

    try list.append(allocator, .{ .offset = descriptor.block_bitmap * block_size, .length = block_size });
    try list.append(allocator, .{ .offset = descriptor.inode_bitmap * block_size, .length = block_size });
    try list.append(allocator, .{ .offset = descriptor.inode_table * block_size, .length = inode_table_blocks * block_size });
}

fn readBlock(io: std.Io, r: *const Reader, block_number: u64, block_size: u32, buffer: []u8) !void {
    if (buffer.len < block_size) return error.InternalBufferTooSmall;
    try r.readExactlyAt(io, buffer[0..block_size], block_number * block_size);
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

// Filesystem driver contract; see driver.zig.

pub const name = "ext4";
/// ext4 is the fallback for Linux partitions, so a failed probe means the
/// partition holds some other Linux filesystem.
pub const unrecognized: types.Info.Filesystem = .linux_unknown;
pub const raw_layout: types.Info.Layout = .raw_ext4;
pub const filesystem: types.Info.Filesystem = .ext4;
pub const blockSize = superblockBlockSize;

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

test "detect accepts valid magic through buffer reader" {
    var bytes: [4096]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[1024 + 56 ..][0..2], ext4_magic, .little);
    // Minimal plausible geometry so validate passes during probe paths.
    std.mem.writeInt(u32, bytes[1024 + 4 ..][0..4], 512, .little); // blocks_count
    std.mem.writeInt(u32, bytes[1024 + 24 ..][0..4], 0, .little); // log_block_size
    std.mem.writeInt(u32, bytes[1024 + 32 ..][0..4], 8, .little); // blocks_per_group
    std.mem.writeInt(u32, bytes[1024 + 40 ..][0..4], 16, .little); // inodes_per_group

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    try std.testing.expect(detect(std.testing.io, &r));

    bytes[1024 + 56] ^= 0xff;
    var bad = reader_mod.Buffer.init(&bytes);
    const br = bad.reader();
    try std.testing.expect(!detect(std.testing.io, &br));
}

/// Writes a one-group ext4 with 1 KiB blocks into `bytes` for hostile-input
/// tests: superblock in block 1, descriptors in block 2, bitmaps in 3 and 4.
fn writeTestExt4(bytes: []u8, blocks_per_group: u32) void {
    @memset(bytes, 0);
    const superblock = bytes[1024..][0..1024];
    std.mem.writeInt(u32, superblock[4..8], @intCast(bytes.len / 1024), .little);
    std.mem.writeInt(u32, superblock[20..24], 1, .little);
    std.mem.writeInt(u32, superblock[32..36], blocks_per_group, .little);
    std.mem.writeInt(u32, superblock[40..44], 32, .little);
    std.mem.writeInt(u16, superblock[56..58], ext4_magic, .little);
    std.mem.writeInt(u32, superblock[76..80], 1, .little);
    std.mem.writeInt(u16, superblock[88..90], 128, .little);

    const descriptor = bytes[2048..][0..64];
    std.mem.writeInt(u32, descriptor[0..4], 3, .little);
    std.mem.writeInt(u32, descriptor[4..8], 4, .little);
    std.mem.writeInt(u32, descriptor[8..12], 5, .little);
}

test "blocks per group beyond one bitmap block is rejected" {
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    // A 1 KiB bitmap describes 8192 blocks; claiming more would read past it.
    writeTestExt4(bytes, 65536);

    var source = reader_mod.Buffer.init(bytes);
    const r = source.reader();
    try std.testing.expectError(error.InvalidExt4Superblock, collectRanges(std.testing.allocator, std.testing.io, &r));
}

test "64-bit block numbers that overflow byte offsets are rejected" {
    var bytes: [256 * 1024]u8 = undefined;
    writeTestExt4(&bytes, 8192);
    const superblock = bytes[1024..][0..1024];
    std.mem.writeInt(u32, superblock[96..100], incompat_sixtyfourbit, .little);
    std.mem.writeInt(u16, superblock[254..256], 64, .little);
    std.mem.writeInt(u32, bytes[2048 + 32 ..][0..4], 0xffff_ffff, .little); // block bitmap, high half

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    if (collectRanges(std.testing.allocator, std.testing.io, &r)) |ranges| {
        std.testing.allocator.free(ranges);
        return error.TestExpectedError;
    } else |_| {}
}
