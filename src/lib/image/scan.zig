const std = @import("std");

const fs = @import("fs.zig");
const mbr = @import("layout/mbr.zig");
const range = @import("../range.zig");

const region_api = @import("region.zig");

pub const ByteRange = range.ByteRange;
pub const Region = region_api.Region;
pub const Filesystem = fs.Filesystem;

pub const Layout = enum {
    raw_ext4,
    raw_iso9660,
    mbr,
};

pub const PartitionProbe = struct {
    index: u8,
    start_offset: u64,
    size: u64,
    partition_type: u8,
    filesystem: Filesystem,
    supported: bool,
    reason: ?[]u8 = null,
    block_size: ?u32 = null,
    required_image_size: ?u64 = null,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
    }
};

pub const Probe = struct {
    image_size: u64,
    layout: Layout,
    filesystem: ?Filesystem = null,
    block_size: ?u32 = null,
    required_image_size: ?u64 = null,
    partitions: []PartitionProbe = &.{},

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.partitions) |partition| partition.deinit(allocator);
        if (self.partitions.len != 0) allocator.free(self.partitions);
    }
};

pub const Analysis = struct {
    probe: Probe,
    used_bytes: ?u64 = null,
    ranges: ?[]ByteRange = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.probe.deinit(allocator);
        if (self.ranges) |ranges| allocator.free(ranges);
    }
};

pub fn probe(bytes: []const u8, allocator: std.mem.Allocator) !Probe {
    if (bytes.len < mbr.sector_size) return error.InvalidImage;

    if (looksLikeIso(bytes)) {
        return .{
            .image_size = bytes.len,
            .layout = .raw_iso9660,
            .filesystem = .iso9660,
            .block_size = 2048,
            .required_image_size = bytes.len,
        };
    }

    var sector: [mbr.sector_size]u8 = undefined;
    @memcpy(&sector, bytes[0..mbr.sector_size]);
    if (!mbr.looksLikeMbr(&sector)) {
        const ext4 = try readExt4Superblock(bytes, .{ .offset = 0, .length = bytes.len });
        return .{
            .image_size = bytes.len,
            .layout = .raw_ext4,
            .filesystem = .ext4,
            .block_size = try ext4.blockSize(),
            .required_image_size = try ext4.filesystemSize(),
        };
    }

    const spans = try mbr.collectPartitionSpans(allocator, &sector, bytes.len);
    defer allocator.free(spans);

    var partitions: std.ArrayList(PartitionProbe) = .empty;
    errdefer {
        for (partitions.items) |partition| partition.deinit(allocator);
        partitions.deinit(allocator);
    }

    for (spans) |span| {
        try partitions.append(allocator, try probePartition(bytes, allocator, span));
    }

    return .{
        .image_size = bytes.len,
        .layout = .mbr,
        .partitions = try partitions.toOwnedSlice(allocator),
    };
}

pub fn analyze(bytes: []const u8, allocator: std.mem.Allocator) !Analysis {
    var result = Analysis{ .probe = try probe(bytes, allocator) };
    errdefer result.deinit(allocator);

    var ranges: std.ArrayList(ByteRange) = .empty;
    errdefer ranges.deinit(allocator);

    switch (result.probe.layout) {
        .raw_iso9660 => try ranges.append(allocator, .{ .offset = 0, .length = bytes.len }),
        .raw_ext4 => {
            const ext4_ranges = try collectExt4Ranges(bytes, allocator, .{ .offset = 0, .length = bytes.len });
            defer allocator.free(ext4_ranges);
            try ranges.appendSlice(allocator, ext4_ranges);
        },
        .mbr => {
            var occupied: std.ArrayList(ByteRange) = .empty;
            defer occupied.deinit(allocator);

            for (result.probe.partitions) |partition| {
                try occupied.append(allocator, .{ .offset = partition.start_offset, .length = partition.size });
                if (!partition.supported) {
                    if (partition.filesystem == .empty) continue;
                    return error.UnsupportedPartitionFilesystem;
                }

                const region: Region = .{ .offset = partition.start_offset, .length = partition.size };
                const partition_ranges = switch (partition.filesystem) {
                    .ext4 => try collectExt4Ranges(bytes, allocator, region),
                    .fat16, .fat32 => try collectFatRanges(bytes, allocator, region),
                    .squashfs => try collectSquashfsRanges(allocator, bytes, region),
                    else => return error.UnsupportedPartitionFilesystem,
                };
                defer allocator.free(partition_ranges);
                for (partition_ranges) |relative| {
                    try ranges.append(allocator, try regionToImageRange(region, relative));
                }
            }

            try appendGapRanges(allocator, &ranges, occupied.items, bytes.len);
        },
    }

    const normalized = try range.normalizeRanges(allocator, ranges.items);
    ranges.deinit(allocator);
    result.ranges = normalized;

    var used_bytes: u64 = 0;
    for (normalized) |item| used_bytes = try std.math.add(u64, used_bytes, item.length);
    result.used_bytes = used_bytes;
    return result;
}

pub fn regionToImageRange(region: Region, relative: ByteRange) !ByteRange {
    if (try relativeEnd(relative) > region.length) return error.RegionOutOfBounds;
    return .{
        .offset = try std.math.add(u64, region.offset, relative.offset),
        .length = relative.length,
    };
}

fn relativeEnd(item: ByteRange) !u64 {
    return std.math.add(u64, item.offset, item.length) catch error.RangeOverflow;
}

fn readBytes(bytes: []const u8, offset: u64, output: []u8) !void {
    const start: usize = std.math.cast(usize, offset) orelse return error.UnexpectedEndOfImage;
    if (start > bytes.len or output.len > bytes.len - start) return error.UnexpectedEndOfImage;
    @memcpy(output, bytes[start .. start + output.len]);
}

fn looksLikeIso(bytes: []const u8) bool {
    const offset: usize = 16 * 2048;
    return bytes.len >= offset + 7 and bytes[offset] == 1 and std.mem.eql(u8, bytes[offset + 1 .. offset + 6], "CD001") and bytes[offset + 6] == 1;
}

fn appendGapRanges(allocator: std.mem.Allocator, ranges: *std.ArrayList(ByteRange), occupied: []const ByteRange, image_size: u64) !void {
    const normalized = try range.normalizeRanges(allocator, occupied);
    defer allocator.free(normalized);

    var cursor: u64 = 0;
    for (normalized) |item| {
        if (cursor < item.offset) try ranges.append(allocator, .{ .offset = cursor, .length = item.offset - cursor });
        cursor = item.end();
    }
    if (cursor < image_size) try ranges.append(allocator, .{ .offset = cursor, .length = image_size - cursor });
}

const Ext4Superblock = struct {
    blocks_count: u64,
    first_data_block: u32,
    log_block_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    rev_level: u32,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    desc_size: u16,
    inode_size: u16,

    fn blockSize(self: @This()) !u32 {
        if (self.log_block_size > 6) return error.UnsupportedExt4Feature;
        return @as(u32, 1024) << @intCast(self.log_block_size);
    }

    fn filesystemSize(self: @This()) !u64 {
        return std.math.mul(u64, self.blocks_count, try self.blockSize());
    }

    fn groupCount(self: @This()) !u64 {
        if (self.blocks_count < self.first_data_block or self.blocks_per_group == 0) return error.InvalidExt4Superblock;
        return std.math.divCeil(u64, self.blocks_count - self.first_data_block, self.blocks_per_group);
    }
};

const ext4_magic: u16 = 0xef53;
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

const GroupDescriptor = struct {
    block_bitmap: u64,
    inode_bitmap: u64,
    inode_table: u64,
    flags: u16,
};

fn readExt4Superblock(bytes: []const u8, region: Region) !Ext4Superblock {
    var buffer: [1024]u8 = undefined;
    if (region.length < 1024 + buffer.len) return error.InvalidExt4Superblock;
    try readBytes(bytes, try std.math.add(u64, region.offset, 1024), &buffer);

    if (readU16(buffer[56..58]) != ext4_magic) return error.InvalidExt4Superblock;
    const superblock = Ext4Superblock{
        .blocks_count = (@as(u64, readU32(buffer[336..340])) << 32) | readU32(buffer[4..8]),
        .first_data_block = readU32(buffer[20..24]),
        .log_block_size = readU32(buffer[24..28]),
        .blocks_per_group = readU32(buffer[32..36]),
        .inodes_per_group = readU32(buffer[40..44]),
        .rev_level = readU32(buffer[76..80]),
        .feature_compat = readU32(buffer[92..96]),
        .feature_incompat = readU32(buffer[96..100]),
        .feature_ro_compat = readU32(buffer[100..104]),
        .desc_size = readU16(buffer[254..256]),
        .inode_size = if (readU32(buffer[76..80]) >= 1) readU16(buffer[88..90]) else 128,
    };
    try validateExt4(superblock, region.length);
    return superblock;
}

fn validateExt4(superblock: Ext4Superblock, region_size: u64) !void {
    if (superblock.blocks_count == 0 or superblock.blocks_per_group == 0 or superblock.inodes_per_group == 0) return error.InvalidExt4Superblock;
    if (try superblock.filesystemSize() > region_size) return error.InvalidExt4Superblock;
    if ((superblock.feature_compat & ~supported_compat) != 0) return error.UnsupportedExt4CompatFeature;
    if ((superblock.feature_incompat & ~supported_incompat) != 0) return error.UnsupportedExt4IncompatFeature;
    if ((superblock.feature_ro_compat & ~supported_ro_compat) != 0) return error.UnsupportedExt4ReadOnlyFeature;
}

fn collectExt4Ranges(bytes: []const u8, allocator: std.mem.Allocator, region: Region) ![]ByteRange {
    const superblock = try readExt4Superblock(bytes, region);
    const block_size = try superblock.blockSize();
    const groups_count = try superblock.groupCount();
    const descriptor_size: u64 = if ((superblock.feature_incompat & incompat_sixtyfourbit) != 0 and superblock.desc_size >= 32) superblock.desc_size else 32;
    if (descriptor_size > block_size) return error.InvalidExt4Superblock;
    const descriptor_blocks = try std.math.divCeil(u64, try std.math.mul(u64, groups_count, descriptor_size), block_size);
    const descriptor_table_block: u64 = if (block_size == 1024) 2 else 1;
    const inode_size: u64 = if (superblock.inode_size >= 128) superblock.inode_size else 128;
    const inode_table_blocks = try std.math.divCeil(u64, try std.math.mul(u64, inode_size, superblock.inodes_per_group), block_size);

    const descriptors = try allocator.alloc(GroupDescriptor, @intCast(groups_count));
    defer allocator.free(descriptors);
    var descriptor_bytes = try allocator.alloc(u8, @intCast(descriptor_size));
    defer allocator.free(descriptor_bytes);

    for (descriptors, 0..) |*descriptor, index| {
        const descriptor_offset = try std.math.add(u64, region.offset, try std.math.add(u64, try std.math.mul(u64, descriptor_table_block, block_size), try std.math.mul(u64, index, descriptor_size)));
        try readBytes(bytes, descriptor_offset, descriptor_bytes);
        const high_bitmap = if (descriptor_size >= 64) readU32(descriptor_bytes[32..36]) else 0;
        const high_inode_bitmap = if (descriptor_size >= 64) readU32(descriptor_bytes[36..40]) else 0;
        const high_inode_table = if (descriptor_size >= 64) readU32(descriptor_bytes[40..44]) else 0;
        descriptor.* = .{
            .block_bitmap = (@as(u64, high_bitmap) << 32) | readU32(descriptor_bytes[0..4]),
            .inode_bitmap = (@as(u64, high_inode_bitmap) << 32) | readU32(descriptor_bytes[4..8]),
            .inode_table = (@as(u64, high_inode_table) << 32) | readU32(descriptor_bytes[8..12]),
            .flags = readU16(descriptor_bytes[18..20]),
        };
    }

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);
    const bitmap = try allocator.alloc(u8, block_size);
    defer allocator.free(bitmap);

    var group: u64 = 0;
    while (group < groups_count) : (group += 1) {
        const first_block = try std.math.add(u64, superblock.first_data_block, try std.math.mul(u64, group, superblock.blocks_per_group));
        if (first_block >= superblock.blocks_count) break;
        const blocks_in_group = @min(@as(u64, superblock.blocks_per_group), superblock.blocks_count - first_block);
        const descriptor = descriptors[@intCast(group)];

        if (groupHasSuperblock(group)) {
            const superblock_block = if (group == 0 and block_size == 1024) 1 else first_block;
            try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, superblock_block, block_size), block_size);
            const descriptor_block = if (group == 0) descriptor_table_block else try std.math.add(u64, superblock_block, 1);
            try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, descriptor_block, block_size), try std.math.mul(u64, descriptor_blocks, block_size));
        }

        try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, descriptor.block_bitmap, block_size), block_size);
        try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, descriptor.inode_bitmap, block_size), block_size);
        try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, descriptor.inode_table, block_size), try std.math.mul(u64, inode_table_blocks, block_size));

        const bitmap_offset = try std.math.add(u64, region.offset, try std.math.mul(u64, descriptor.block_bitmap, block_size));
        try readBytes(bytes, bitmap_offset, bitmap);
        var block: u64 = 0;
        while (block < blocks_in_group) : (block += 1) {
            if ((bitmap[@intCast(block / 8)] & (@as(u8, 1) << @intCast(block % 8))) == 0) continue;
            try appendExt4Range(&ranges, allocator, region, try std.math.mul(u64, try std.math.add(u64, first_block, block), block_size), block_size);
        }
    }

    return range.normalizeRanges(allocator, ranges.items);
}

fn appendExt4Range(ranges: *std.ArrayList(ByteRange), allocator: std.mem.Allocator, region: Region, offset: u64, length: u64) !void {
    const relative = ByteRange{ .offset = offset, .length = length };
    if (try relativeEnd(relative) > region.length) return error.InvalidExt4Superblock;
    try ranges.append(allocator, relative);
}

fn groupHasSuperblock(group: u64) bool {
    if (group <= 1) return true;
    return isPowerOf(group, 3) or isPowerOf(group, 5) or isPowerOf(group, 7);
}

fn isPowerOf(value: u64, base: u64) bool {
    if (value == 0) return false;
    var current = value;
    while (current % base == 0) current /= base;
    return current == 1;
}

const FatBoot = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sector_count: u16,
    num_fats: u8,
    root_dir_sectors: u32,
    total_sectors: u32,
    fat_size_sectors: u32,
    first_data_sector: u32,
    total_clusters: u32,
    filesystem: Filesystem,
};

fn readFatBoot(bytes: []const u8, region: Region) !FatBoot {
    var sector: [512]u8 = undefined;
    if (region.length < sector.len) return error.InvalidFatBootSector;
    try readBytes(bytes, region.offset, &sector);
    if (readU16(sector[510..512]) != 0xaa55) return error.InvalidFatBootSector;

    const bytes_per_sector = readU16(sector[11..13]);
    const sectors_per_cluster = sector[13];
    const reserved = readU16(sector[14..16]);
    const num_fats = sector[16];
    const root_entries = readU16(sector[17..19]);
    const total16 = readU16(sector[19..21]);
    const fat16 = readU16(sector[22..24]);
    const total32 = readU32(sector[32..36]);
    const fat32 = readU32(sector[36..40]);
    if (bytes_per_sector == 0 or sectors_per_cluster == 0 or reserved == 0 or num_fats == 0) return error.InvalidFatBootSector;

    const total = if (total16 != 0) total16 else total32;
    const fat_size = if (fat16 != 0) fat16 else fat32;
    if (total == 0 or fat_size == 0) return error.InvalidFatBootSector;
    const root_dir = ((@as(u32, root_entries) * 32) + bytes_per_sector - 1) / bytes_per_sector;
    const first_data = @as(u32, reserved) + (@as(u32, num_fats) * fat_size) + root_dir;
    if (first_data >= total) return error.InvalidFatBootSector;
    const data_sectors = total - first_data;
    const clusters = data_sectors / sectors_per_cluster;
    if (clusters < 1) return error.InvalidFatBootSector;
    const partition_size = try std.math.mul(u64, total, bytes_per_sector);
    if (partition_size > region.length) return error.InvalidFatBootSector;

    return .{
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sector_count = reserved,
        .num_fats = num_fats,
        .root_dir_sectors = root_dir,
        .total_sectors = total,
        .fat_size_sectors = fat_size,
        .first_data_sector = first_data,
        .total_clusters = clusters,
        .filesystem = if (clusters < 65525) .fat16 else .fat32,
    };
}

fn collectFatRanges(bytes: []const u8, allocator: std.mem.Allocator, region: Region) ![]ByteRange {
    const boot = try readFatBoot(bytes, region);
    const fat_length = try std.math.mul(u64, boot.fat_size_sectors, boot.bytes_per_sector);
    const fat_offset = try std.math.mul(u64, boot.reserved_sector_count, boot.bytes_per_sector);
    var fat = try allocator.alloc(u8, @intCast(fat_length));
    defer allocator.free(fat);
    try readBytes(bytes, try std.math.add(u64, region.offset, fat_offset), fat);

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);
    try ranges.append(allocator, .{ .offset = 0, .length = try std.math.mul(u64, boot.first_data_sector, boot.bytes_per_sector) });
    const cluster_length = try std.math.mul(u64, boot.bytes_per_sector, boot.sectors_per_cluster);
    var cluster: u32 = 2;
    while (cluster < boot.total_clusters + 2) : (cluster += 1) {
        const allocated = switch (boot.filesystem) {
            .fat16 => blk: {
                const offset = @as(u64, cluster) * 2;
                if (offset + 2 > fat.len) break :blk false;
                break :blk readU16(fat[@intCast(offset)..][0..2]) != 0;
            },
            .fat32 => blk: {
                const offset = @as(u64, cluster) * 4;
                if (offset + 4 > fat.len) break :blk false;
                break :blk (readU32(fat[@intCast(offset)..][0..4]) & 0x0fffffff) != 0;
            },
            else => false,
        };
        if (!allocated) continue;
        const data_sector = try std.math.add(u64, boot.first_data_sector, (@as(u64, cluster - 2) * boot.sectors_per_cluster));
        try ranges.append(allocator, .{ .offset = try std.math.mul(u64, data_sector, boot.bytes_per_sector), .length = cluster_length });
    }
    return range.normalizeRanges(allocator, ranges.items);
}

fn collectSquashfsRanges(allocator: std.mem.Allocator, bytes: []const u8, region: Region) ![]ByteRange {
    var buffer: [96]u8 = undefined;
    try readBytes(bytes, region.offset, &buffer);
    if (readU32(buffer[0..4]) != 0x73717368) return error.InvalidSquashfsSuperblock;
    const block_size = readU32(buffer[12..16]);
    const bytes_used = readU64(buffer[40..48]);
    if (block_size == 0 or bytes_used == 0 or bytes_used > region.length) return error.InvalidSquashfsSuperblock;
    const ranges = try allocator.alloc(ByteRange, 1);
    ranges[0] = .{ .offset = 0, .length = bytes_used };
    return ranges;
}

fn probePartition(bytes: []const u8, allocator: std.mem.Allocator, span: mbr.PartitionSpan) !PartitionProbe {
    if (span.partition_type == 0x0b or span.partition_type == 0x0c or span.partition_type == 0x0e) {
        const boot = readFatBoot(bytes, .{ .offset = span.start_offset, .length = span.size }) catch |err| return unsupportedPartition(allocator, span, .unknown, "FAT probe failed", err);
        return .{ .index = span.index, .start_offset = span.start_offset, .size = span.size, .partition_type = span.partition_type, .filesystem = boot.filesystem, .supported = true, .block_size = @intCast(@as(u64, boot.bytes_per_sector) * boot.sectors_per_cluster), .required_image_size = span.size };
    }

    if (span.partition_type == 0x83) {
        var magic: [4]u8 = undefined;
        readBytes(bytes, span.start_offset, &magic) catch |err| return unsupportedPartition(allocator, span, .unknown, "partition probe failed", err);
        if (std.mem.eql(u8, &magic, "hsqs")) {
            var header: [96]u8 = undefined;
            readBytes(bytes, span.start_offset, &header) catch |err| return unsupportedPartition(allocator, span, .squashfs, "invalid SquashFS superblock", err);
            const block_size = readU32(header[12..16]);
            const bytes_used = readU64(header[40..48]);
            if (block_size != 0 and bytes_used != 0 and bytes_used <= span.size) return .{ .index = span.index, .start_offset = span.start_offset, .size = span.size, .partition_type = span.partition_type, .filesystem = .squashfs, .supported = true, .block_size = block_size, .required_image_size = try std.math.add(u64, span.start_offset, bytes_used) };
            return unsupportedPartition(allocator, span, .squashfs, "invalid SquashFS superblock", error.InvalidSquashfsSuperblock);
        }

        const ext4 = readExt4Superblock(bytes, .{ .offset = span.start_offset, .length = span.size }) catch |err| {
            if (partitionIsEmpty(bytes, span)) return .{ .index = span.index, .start_offset = span.start_offset, .size = span.size, .partition_type = span.partition_type, .filesystem = .empty, .supported = false, .reason = try allocator.dupe(u8, "partition appears empty") };
            return unsupportedPartition(allocator, span, .linux_unknown, "ext4 probe failed", err);
        };
        return .{ .index = span.index, .start_offset = span.start_offset, .size = span.size, .partition_type = span.partition_type, .filesystem = .ext4, .supported = true, .block_size = try ext4.blockSize(), .required_image_size = try std.math.add(u64, span.start_offset, try ext4.filesystemSize()) };
    }

    return unsupportedPartition(allocator, span, .unknown, "unknown partition type", error.UnknownPartitionType);
}

fn partitionIsEmpty(bytes: []const u8, span: mbr.PartitionSpan) bool {
    const length = @min(span.size, @as(u64, 4096));
    const start = std.math.cast(usize, span.start_offset) orelse return false;
    if (start > bytes.len or length > bytes.len - start) return true;
    for (bytes[start .. start + @as(usize, @intCast(length))]) |byte| if (byte != 0) return false;
    return true;
}

fn unsupportedPartition(allocator: std.mem.Allocator, span: mbr.PartitionSpan, filesystem: Filesystem, message: []const u8, err: anyerror) !PartitionProbe {
    const reason = std.fmt.allocPrint(allocator, "{s}: {t}", .{ message, err }) catch try allocator.dupe(u8, message);
    return .{ .index = span.index, .start_offset = span.start_offset, .size = span.size, .partition_type = span.partition_type, .filesystem = filesystem, .supported = false, .reason = reason };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}
