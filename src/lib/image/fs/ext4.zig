const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

pub const ByteRange = range.ByteRange;
pub const ImageInfo = types.Info;
pub const PartitionInfo = types.Info.PartitionInfo;
pub const Reader = reader_mod.Reader;

const ondisk = @import("../ondisk.zig");
const mbr = @import("../layout/mbr.zig");
const scan = @import("../../scan.zig");

const superblock_offset: u64 = 1024;
const sector_size: usize = 512;
const ext4_magic: u16 = 0xEF53;

/// On-disk ext4 structures, as laid out in the kernel's ext4 documentation.
const OnDisk = struct {
    const Superblock = extern struct {
        inodes_count: u32,
        blocks_count_lo: u32,
        _counts: [12]u8,
        first_data_block: u32,
        log_block_size: u32,
        log_cluster_size: u32,
        blocks_per_group: u32,
        clusters_per_group: u32,
        inodes_per_group: u32,
        _times: [12]u8,
        magic: u16,
        state: u16,
        _errors_to_creator_os: [16]u8,
        rev_level: u32,
        _reserved_ids_first_ino: [8]u8,
        inode_size: u16,
        block_group_nr: u16,
        feature_compat: CompatFeatures,
        feature_incompat: IncompatFeatures,
        feature_ro_compat: RoCompatFeatures,
        _uuid_to_hash_version: [0x96]u8,
        desc_size: u16,
        _mount_opts_to_jnl_blocks: [0x50]u8,
        blocks_count_hi: u32,
        _rest: [0x400 - 0x154]u8,
    };

    /// The 64-byte descriptor. Filesystems without the 64bit feature store
    /// only the first 32 bytes; the high halves then read as zero.
    const GroupDescriptor = extern struct {
        block_bitmap_lo: u32,
        inode_bitmap_lo: u32,
        inode_table_lo: u32,
        free_blocks_count_lo: u16,
        free_inodes_count_lo: u16,
        used_dirs_count_lo: u16,
        flags: u16,
        _exclude_bitmap_to_checksum: [12]u8,
        block_bitmap_hi: u32,
        inode_bitmap_hi: u32,
        inode_table_hi: u32,
        free_blocks_count_hi: u16,
        _rest: [18]u8,
    };

    const CompatFeatures = packed struct(u32) {
        dir_prealloc: bool = false,
        imagic_inodes: bool = false,
        has_journal: bool = false,
        ext_attr: bool = false,
        resize_inode: bool = false,
        dir_index: bool = false,
        lazy_bg: bool = false,
        exclude_inode: bool = false,
        exclude_bitmap: bool = false,
        sparse_super2: bool = false,
        fast_commit: bool = false,
        stable_inodes: bool = false,
        orphan_file: bool = false,
        _unknown: u19 = 0,
    };

    const IncompatFeatures = packed struct(u32) {
        compression: bool = false,
        filetype: bool = false,
        recover: bool = false,
        journal_dev: bool = false,
        meta_bg: bool = false,
        _unused_5: bool = false,
        extents: bool = false,
        @"64bit": bool = false,
        mmp: bool = false,
        flex_bg: bool = false,
        ea_inode: bool = false,
        _unused_11: bool = false,
        dirdata: bool = false,
        csum_seed: bool = false,
        largedir: bool = false,
        inline_data: bool = false,
        encrypt: bool = false,
        casefold: bool = false,
        _unknown: u14 = 0,
    };

    const RoCompatFeatures = packed struct(u32) {
        sparse_super: bool = false,
        large_file: bool = false,
        btree_dir: bool = false,
        huge_file: bool = false,
        gdt_csum: bool = false,
        dir_nlink: bool = false,
        extra_isize: bool = false,
        has_snapshot: bool = false,
        quota: bool = false,
        bigalloc: bool = false,
        metadata_csum: bool = false,
        replica: bool = false,
        readonly: bool = false,
        project: bool = false,
        shared_blocks: bool = false,
        verity: bool = false,
        orphan_present: bool = false,
        _unknown: u15 = 0,
    };

    comptime {
        ondisk.expectLayout(OnDisk.Superblock, 1024, .{
            .blocks_count_lo = 0x04,
            .first_data_block = 0x14,
            .log_block_size = 0x18,
            .blocks_per_group = 0x20,
            .inodes_per_group = 0x28,
            .magic = 0x38,
            .state = 0x3A,
            .rev_level = 0x4C,
            .inode_size = 0x58,
            .feature_compat = 0x5C,
            .feature_incompat = 0x60,
            .feature_ro_compat = 0x64,
            .desc_size = 0xFE,
            .blocks_count_hi = 0x150,
        });
        ondisk.expectLayout(OnDisk.GroupDescriptor, 64, .{
            .block_bitmap_lo = 0x00,
            .inode_bitmap_lo = 0x04,
            .inode_table_lo = 0x08,
            .free_blocks_count_lo = 0x0C,
            .flags = 0x12,
            .block_bitmap_hi = 0x20,
            .inode_bitmap_hi = 0x24,
            .inode_table_hi = 0x28,
            .free_blocks_count_hi = 0x2C,
        });
    }
};

/// Features the planner can handle: none of them moves group metadata or
/// changes what a block bitmap bit means. Anything else is rejected.
const supported_compat: OnDisk.CompatFeatures = .{
    .has_journal = true,
    .ext_attr = true,
    .resize_inode = true,
    .dir_index = true,
    .sparse_super2 = true,
    .stable_inodes = true,
    .orphan_file = true,
};
const supported_incompat: OnDisk.IncompatFeatures = .{
    .filetype = true,
    .recover = true,
    .extents = true,
    .@"64bit" = true,
    .flex_bg = true,
    .dirdata = true,
    .csum_seed = true,
};
const supported_ro_compat: OnDisk.RoCompatFeatures = .{
    .sparse_super = true,
    .large_file = true,
    .huge_file = true,
    .dir_nlink = true,
    .extra_isize = true,
    .quota = true,
    .metadata_csum = true,
};

/// True when `present` sets any flag `supported` does not.
fn hasUnsupported(comptime Features: type, present: Features, supported: Features) bool {
    const Bits = @typeInfo(Features).@"struct".backing_integer.?;
    return @as(Bits, @bitCast(present)) & ~@as(Bits, @bitCast(supported)) != 0;
}

const Superblock = struct {
    blocks_count: u64,
    first_data_block: u32,
    log_block_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    magic: u16,
    state: u16,
    rev_level: u32,
    feature_compat: OnDisk.CompatFeatures,
    feature_incompat: OnDisk.IncompatFeatures,
    feature_ro_compat: OnDisk.RoCompatFeatures,
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
    const magic_offset = superblock_offset + @offsetOf(OnDisk.Superblock, "magic");
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

        // One range per run of used blocks, found a bitmap word at a time.
        var runs = scan.SetRuns.init(bitmap_buffer, blocks_in_group);
        while (runs.next()) |run| {
            try range.appendCoalesced(allocator, &used_blocks, .{
                .offset = (group_first_block + run.start) * block_size,
                .length = (run.end - run.start) * block_size,
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
    const raw = try ondisk.read(OnDisk.Superblock, io, r, superblock_offset);
    if (raw.magic != ext4_magic) return error.InvalidExt4Superblock;

    // Revision 0 filesystems predate these fields and leave them undefined.
    const dynamic = raw.rev_level >= 1;
    return .{
        .blocks_count = (@as(u64, if (dynamic) raw.blocks_count_hi else 0) << 32) | raw.blocks_count_lo,
        .first_data_block = raw.first_data_block,
        .log_block_size = raw.log_block_size,
        .blocks_per_group = raw.blocks_per_group,
        .inodes_per_group = raw.inodes_per_group,
        .magic = raw.magic,
        .state = raw.state,
        .rev_level = raw.rev_level,
        .feature_compat = raw.feature_compat,
        .feature_incompat = raw.feature_incompat,
        .feature_ro_compat = raw.feature_ro_compat,
        .desc_size = raw.desc_size,
        .inode_size = if (dynamic) raw.inode_size else 128,
    };
}

fn rejectUnsupportedImageLayout(io: std.Io, file: std.Io.File, image_size: u64) !void {
    if (image_size < sector_size) return;

    var sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &sector, 0);
    if (count != sector.len) return error.InvalidExt4Superblock;

    if (!mbr.looksLikeMbr(&sector)) return;
    return error.UnsupportedImageLayout;
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

    if (hasUnsupported(OnDisk.CompatFeatures, superblock.feature_compat, supported_compat)) return error.UnsupportedExt4CompatFeature;
    if (hasUnsupported(OnDisk.IncompatFeatures, superblock.feature_incompat, supported_incompat)) return error.UnsupportedExt4IncompatFeature;
    if (hasUnsupported(OnDisk.RoCompatFeatures, superblock.feature_ro_compat, supported_ro_compat)) return error.UnsupportedExt4ReadOnlyFeature;
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
    if (superblock.feature_incompat.@"64bit" and superblock.desc_size >= 32) {
        return superblock.desc_size;
    }
    return 32;
}

fn inodeSize(superblock: Superblock) u16 {
    return if (superblock.inode_size >= 128) superblock.inode_size else 128;
}

/// Reads the whole descriptor table in one request and decodes each entry.
fn readGroupDescriptors(io: std.Io, allocator: std.mem.Allocator, r: *const Reader, descriptors: []GroupDescriptor, descriptor_table_block: u64, desc_size: u64, block_size: u32) !void {
    const entry_size: usize = @intCast(desc_size);
    const table_len = std.math.mul(usize, descriptors.len, entry_size) catch return error.InvalidExt4Superblock;
    const table = try allocator.alloc(u8, table_len);
    defer allocator.free(table);
    try r.readExactlyAt(io, table, descriptor_table_block * block_size);

    for (descriptors, 0..) |*descriptor, index| {
        var entry: [@sizeOf(OnDisk.GroupDescriptor)]u8 = @splat(0);
        const stored = @min(entry_size, entry.len);
        @memcpy(entry[0..stored], table[index * entry_size ..][0..stored]);
        const raw = ondisk.decode(OnDisk.GroupDescriptor, &entry);

        descriptor.* = .{
            .block_bitmap = (@as(u64, raw.block_bitmap_hi) << 32) | raw.block_bitmap_lo,
            .inode_bitmap = (@as(u64, raw.inode_bitmap_hi) << 32) | raw.inode_bitmap_lo,
            .inode_table = (@as(u64, raw.inode_table_hi) << 32) | raw.inode_table_lo,
            .free_blocks_count = (@as(u32, raw.free_blocks_count_hi) << 16) | raw.free_blocks_count_lo,
            .flags = raw.flags,
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
    std.mem.writeInt(u32, superblock[0x60..0x64], @bitCast(OnDisk.IncompatFeatures{ .@"64bit" = true }), .little);
    std.mem.writeInt(u16, superblock[254..256], 64, .little);
    std.mem.writeInt(u32, bytes[2048 + 32 ..][0..4], 0xffff_ffff, .little); // block bitmap, high half

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    if (collectRanges(std.testing.allocator, std.testing.io, &r)) |ranges| {
        std.testing.allocator.free(ranges);
        return error.TestExpectedError;
    } else |_| {}
}
