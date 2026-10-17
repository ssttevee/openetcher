//! Fuzz harness for image analysis.
//!
//! Every layout and filesystem parser reads untrusted bytes through `Reader`,
//! so one target covers them all: start from a small valid image, let the
//! fuzzer patch bytes, and require analysis to either fail cleanly or return
//! a self-consistent plan. Panics, leaks, and broken invariants fail the test.
//!
//! `zig build test` replays only the seeds. `zig build test --fuzz` searches.

const std = @import("std");

const image = @import("../image.zig");
const ByteRange = @import("../range.zig").ByteRange;

const sector = 512;

test "fuzz image analysis" {
    var seeds: Seeds = try .init(std.testing.allocator);
    defer seeds.deinit(std.testing.allocator);
    try std.testing.fuzz(&seeds, analyzeMutated, .{});
}

test "every seed analyzes into a consistent plan" {
    var seeds: Seeds = try .init(std.testing.allocator);
    defer seeds.deinit(std.testing.allocator);

    // A seed that fails to parse would leave its format unfuzzed.
    const expected = [_]image.Info.Filesystem{ .iso9660, .ext4, .fat16, .fat16, .squashfs, .ext4 };
    for (seeds.images, expected) |bytes, filesystem| {
        var analysis = try image.analyzeBytes(std.testing.io, std.testing.allocator, bytes);
        defer analysis.deinit(std.testing.allocator);
        try std.testing.expect(analysis.ranges != null);
        try checkInvariants(analysis);

        const info = analysis.info;
        const actual = info.filesystem orelse info.partitions[0].filesystem;
        try std.testing.expectEqual(filesystem, actual);
        if (info.partitions.len != 0) try std.testing.expect(info.partitions[0].supported);
    }
}

fn analyzeMutated(seeds: *const Seeds, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    const seed = smith.index(seeds.images.len);
    const bytes = try allocator.dupe(u8, seeds.images[seed]);
    defer allocator.free(bytes);

    while (!smith.eosWeightedSimple(7, 1)) {
        // Most patches hit a structure header, where every byte is parsed;
        // the rest land anywhere in the first 64 KiB.
        const offset = if (smith.boolWeighted(1, 3)) at: {
            const anchors = Seeds.anchors[seed];
            const anchor = anchors[smith.index(anchors.len)];
            break :at anchor + smith.index(@min(1024, bytes.len - anchor));
        } else smith.index(@min(bytes.len, 64 * 1024));

        if (smith.boolWeighted(1, 1)) {
            bytes[offset] = smith.value(u8);
        } else if (offset + 4 <= bytes.len) {
            // Header fields are mostly sizes and counts, so boundary values
            // find overflows that uniform values rarely reach.
            const value = if (smith.boolWeighted(1, 1))
                boundary_values[smith.index(boundary_values.len)]
            else
                smith.value(u32);
            std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
        }
    }

    var analysis = image.analyzeBytes(std.testing.io, allocator, bytes) catch return;
    defer analysis.deinit(allocator);
    checkInvariants(analysis) catch |err| {
        reportAnalysis(analysis);
        return err;
    };
}

const boundary_values = [_]u32{ 0, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff, 0x1_0000, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff };

fn reportAnalysis(analysis: image.Analysis) void {
    const info = analysis.info;
    std.debug.print("analysis broke an invariant: layout={t} filesystem={?t} image_size={d}\n", .{ info.layout, info.filesystem, info.image_size });
    for (info.partitions) |partition| {
        std.debug.print("  partition {d}: type=0x{x:0>2} filesystem={t} start={d} size={d}\n", .{ partition.index, partition.partition_type, partition.filesystem, partition.start_offset, partition.size });
    }
    if (analysis.ranges) |ranges| for (ranges) |item| std.debug.print("  range {d}+{d}\n", .{ item.offset, item.length });
}

fn checkInvariants(analysis: image.Analysis) !void {
    const info = analysis.info;
    const ranges = analysis.ranges orelse {
        // A missing plan must be explained by an unsupported partition.
        try std.testing.expect(info.firstUnsupportedPartition() != null);
        return;
    };

    var used: u64 = 0;
    var previous_end: u64 = 0;
    for (ranges, 0..) |item, index| {
        try std.testing.expect(item.length != 0);
        if (index != 0) try std.testing.expect(item.offset > previous_end);
        const end = try std.math.add(u64, item.offset, item.length);
        try std.testing.expect(end <= info.image_size);
        previous_end = end;
        used += item.length;
    }
    try std.testing.expectEqual(@as(?u64, used), info.used_bytes);
    try std.testing.expectEqual(@as(?u64, info.image_size - used), info.skipped_bytes);
    try std.testing.expectEqual(@as(?usize, ranges.len), info.range_count);
}

/// Small valid images, one per format and layout the analyzer routes.
const Seeds = struct {
    images: [6][]u8,

    /// Header offsets in each seed, in `init` order.
    const anchors = [6][]const usize{
        &.{ 0, 16 * 2048 },
        &.{ 1024, 2048, 3072 },
        &.{ 0, 446, sector, 2 * sector },
        &.{ 0, 446, sector, 2 * sector },
        &.{ 0, 446, sector },
        &.{ 0, 446, 8 * sector + 1024, 8 * sector + 2048, 8 * sector + 3072 },
    };

    fn init(allocator: std.mem.Allocator) !Seeds {
        var seeds: Seeds = undefined;
        var built: usize = 0;
        errdefer for (seeds.images[0..built]) |bytes| allocator.free(bytes);

        const builders = [_]*const fn (std.mem.Allocator) anyerror![]u8{ rawIso9660, rawExt4, mbrFatAndEmpty, mbrFatWide, mbrSquashfs, mbrExt4 };
        for (builders, 0..) |build, index| {
            seeds.images[index] = try build(allocator);
            built += 1;
        }
        return seeds;
    }

    fn deinit(self: *Seeds, allocator: std.mem.Allocator) void {
        for (self.images) |bytes| allocator.free(bytes);
    }
};

fn zeroed(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, len);
    @memset(bytes, 0);
    return bytes;
}

fn rawIso9660(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try zeroed(allocator, 18 * 2048);
    bytes[16 * 2048] = 1;
    @memcpy(bytes[16 * 2048 + 1 ..][0..5], "CD001");
    bytes[16 * 2048 + 6] = 1;
    return bytes;
}

fn rawExt4(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try zeroed(allocator, ext4_size);
    writeExt4(bytes);
    return bytes;
}

fn mbrFatAndEmpty(allocator: std.mem.Allocator) ![]u8 {
    const fat_start = 1;
    const fat_sectors = 1024;
    const empty_start = fat_start + fat_sectors;
    const empty_sectors = 64;
    const bytes = try zeroed(allocator, (empty_start + empty_sectors) * sector);
    writePartition(bytes, 0, 0x06, fat_start, fat_sectors);
    writePartition(bytes, 1, 0x83, empty_start, empty_sectors);
    writeMbrSignature(bytes);

    const fat = bytes[fat_start * sector ..];
    std.mem.writeInt(u16, fat[11..13], sector, .little); // bytes per sector
    fat[13] = 4; // sectors per cluster
    std.mem.writeInt(u16, fat[14..16], 1, .little); // reserved sectors
    fat[16] = 2; // FAT count
    std.mem.writeInt(u16, fat[17..19], 512, .little); // root entries
    std.mem.writeInt(u16, fat[19..21], fat_sectors, .little); // total sectors
    std.mem.writeInt(u16, fat[22..24], 2, .little); // sectors per FAT
    std.mem.writeInt(u16, fat[510..512], 0xAA55, .little);
    // Mark the first data clusters allocated in the first FAT.
    std.mem.writeInt(u16, fat[sector + 4 ..][0..2], 0xffff, .little);
    std.mem.writeInt(u16, fat[sector + 6 ..][0..2], 0xffff, .little);
    return bytes;
}

/// The FAT seed with its sizes in the 32-bit BPB fields, so mutations reach
/// the parsing paths only FAT32-style headers use.
fn mbrFatWide(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try mbrFatAndEmpty(allocator);
    const fat = bytes[sector..];
    const total_sectors = std.mem.readInt(u16, fat[19..21], .little);
    const fat_sectors = std.mem.readInt(u16, fat[22..24], .little);
    std.mem.writeInt(u16, fat[19..21], 0, .little);
    std.mem.writeInt(u16, fat[22..24], 0, .little);
    std.mem.writeInt(u32, fat[32..36], total_sectors, .little);
    std.mem.writeInt(u32, fat[36..40], fat_sectors, .little);
    return bytes;
}

fn mbrSquashfs(allocator: std.mem.Allocator) ![]u8 {
    const start = 1;
    const sectors = 64;
    const bytes = try zeroed(allocator, (start + sectors) * sector);
    writePartition(bytes, 0, 0x83, start, sectors);
    writeMbrSignature(bytes);

    const squashfs = bytes[start * sector ..];
    std.mem.writeInt(u32, squashfs[0..4], 0x73717368, .little);
    std.mem.writeInt(u32, squashfs[12..16], 131072, .little); // block size
    std.mem.writeInt(u64, squashfs[40..48], 4096, .little); // bytes used
    return bytes;
}

fn mbrExt4(allocator: std.mem.Allocator) ![]u8 {
    const start = 8;
    const sectors = ext4_size / sector;
    const bytes = try zeroed(allocator, (start + sectors) * sector);
    writePartition(bytes, 0, 0x83, start, sectors);
    writeMbrSignature(bytes);
    writeExt4(bytes[start * sector ..][0..ext4_size]);
    return bytes;
}

const ext4_block_size = 1024;
const ext4_blocks = 256;
const ext4_size = ext4_blocks * ext4_block_size;

/// One block group of 1 KiB blocks: superblock in block 1, descriptors in
/// block 2, bitmaps in blocks 3 and 4, a 4-block inode table from block 5.
fn writeExt4(bytes: []u8) void {
    const superblock = bytes[1024..][0..1024];
    std.mem.writeInt(u32, superblock[0..4], 32, .little); // inodes
    std.mem.writeInt(u32, superblock[4..8], ext4_blocks, .little);
    std.mem.writeInt(u32, superblock[20..24], 1, .little); // first data block
    std.mem.writeInt(u32, superblock[24..28], 0, .little); // 1 KiB blocks
    std.mem.writeInt(u32, superblock[32..36], 8192, .little); // blocks per group
    std.mem.writeInt(u32, superblock[40..44], 32, .little); // inodes per group
    std.mem.writeInt(u16, superblock[56..58], 0xEF53, .little);
    std.mem.writeInt(u32, superblock[76..80], 1, .little); // dynamic revision
    std.mem.writeInt(u16, superblock[88..90], 128, .little); // inode size

    const descriptor = bytes[2 * ext4_block_size ..][0..32];
    std.mem.writeInt(u32, descriptor[0..4], 3, .little); // block bitmap
    std.mem.writeInt(u32, descriptor[4..8], 4, .little); // inode bitmap
    std.mem.writeInt(u32, descriptor[8..12], 5, .little); // inode table

    // Blocks 1-8 (metadata) and 20-23 (file data) in use.
    const bitmap = bytes[3 * ext4_block_size ..];
    bitmap[0] = 0xff;
    bitmap[2] = 0xf0;
    bitmap[3] = 0x00;
}

fn writePartition(bytes: []u8, slot: usize, partition_type: u8, start_lba: u32, sectors: u32) void {
    const entry = bytes[446 + slot * 16 ..][0..16];
    entry[4] = partition_type;
    std.mem.writeInt(u32, entry[8..12], start_lba, .little);
    std.mem.writeInt(u32, entry[12..16], sectors, .little);
}

fn writeMbrSignature(bytes: []u8) void {
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);
}
