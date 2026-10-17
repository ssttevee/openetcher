const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");
const driver_api = @import("driver.zig");

pub const ByteRange = range.ByteRange;
pub const PartitionInfo = types.Info.PartitionInfo;
pub const Filesystem = types.Info.Filesystem;
pub const Reader = reader_mod.Reader;

const sector_size: u64 = 512;

/// MBR partition-type bytes historically holding FAT.
const mbr_types = [_]u8{ 0x06, 0x0b, 0x0c, 0x0e };

const BootSector = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sector_count: u16,
    num_fats: u8,
    root_entry_count: u16,
    total_sectors: u32,
    fat_size_sectors: u32,
    root_dir_sectors: u32,
    first_data_sector: u32,
    total_clusters: u32,
    filesystem: Filesystem,

    fn clusterFirstSector(self: BootSector, cluster: u32) u64 {
        const data_sector = self.first_data_sector + ((cluster - 2) * self.sectors_per_cluster);
        return @as(u64, data_sector) * self.bytes_per_sector;
    }

    fn clusterLength(self: BootSector) u64 {
        return @as(u64, self.bytes_per_sector) * self.sectors_per_cluster;
    }

    fn fatOffset(self: BootSector, fat_index: u8) u64 {
        const sector = self.reserved_sector_count + (@as(u32, fat_index) * self.fat_size_sectors);
        return @as(u64, sector) * self.bytes_per_sector;
    }

    fn fatLength(self: BootSector) u64 {
        return @as(u64, self.fat_size_sectors) * self.bytes_per_sector;
    }
};

/// Reader-core API. All offsets and ranges use reader coordinates.
pub fn detect(io: std.Io, r: *const Reader) bool {
    _ = readBootSector(io, r, r.size) catch return false;
    return true;
}

pub fn probeRegion(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) anyerror!PartitionInfo {
    const boot = try readBootSector(io, r, r.size);
    const ranges = try collectRanges(allocator, io, r);
    defer allocator.free(ranges);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .index = 0,
        .start_offset = 0,
        .size = r.size,
        .partition_type = 0,
        .filesystem = boot.filesystem,
        .supported = true,
        .block_size = @intCast(boot.clusterLength()),
        .used_bytes = used_bytes,
        .skipped_bytes = r.size - used_bytes,
        .range_count = ranges.len,
    };
}

pub fn collectRanges(allocator: std.mem.Allocator, io: std.Io, r: *const Reader) ![]ByteRange {
    const boot = try readBootSector(io, r, r.size);

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);

    try ranges.append(allocator, .{
        .offset = 0,
        .length = @as(u64, boot.first_data_sector) * boot.bytes_per_sector,
    });

    const fat = try allocator.alloc(u8, @intCast(boot.fatLength()));
    defer allocator.free(fat);
    try r.readExactlyAt(io, fat, boot.fatOffset(0));

    var cluster: u32 = 2;
    while (cluster < boot.total_clusters + 2) : (cluster += 1) {
        if (!clusterAllocated(boot.filesystem, fat, cluster)) continue;
        try ranges.append(allocator, .{
            .offset = boot.clusterFirstSector(cluster),
            .length = boot.clusterLength(),
        });
    }

    return range.normalizeRanges(allocator, ranges.items);
}

// File-handle wrappers kept for library callers.

pub fn probeFatPartition(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) !PartitionInfo {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    var partition = try probeRegion(allocator, io, &r);
    partition.start_offset = start_offset;
    return partition;
}

pub fn collectFatRangesInRegion(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, start_offset: u64, size: u64) ![]ByteRange {
    var region = reader_mod.FileRegion.init(io, file, start_offset, size);
    const r = region.reader();
    return collectRanges(allocator, io, &r);
}

fn readBootSector(io: std.Io, r: *const Reader, size: u64) !BootSector {
    var sector: [sector_size]u8 = undefined;
    if (r.size < sector.len) return error.InvalidFatBootSector;
    try r.readExactlyAt(io, &sector, 0);
    if (std.mem.readInt(u16, sector[510..512], .little) != 0xAA55) return error.InvalidFatBootSector;

    const bytes_per_sector = readU16(sector[11..13]);
    const sectors_per_cluster = sector[13];
    const reserved_sector_count = readU16(sector[14..16]);
    const num_fats = sector[16];
    const root_entry_count = readU16(sector[17..19]);
    const total_sectors_16 = readU16(sector[19..21]);
    const fat_size_16 = readU16(sector[22..24]);
    const total_sectors_32 = readU32(sector[32..36]);
    const fat_size_32 = readU32(sector[36..40]);

    if (bytes_per_sector == 0 or sectors_per_cluster == 0 or reserved_sector_count == 0 or num_fats == 0) {
        return error.InvalidFatBootSector;
    }

    const total_sectors = if (total_sectors_16 != 0) total_sectors_16 else total_sectors_32;
    const fat_size_sectors = if (fat_size_16 != 0) fat_size_16 else fat_size_32;
    if (total_sectors == 0 or fat_size_sectors == 0) return error.InvalidFatBootSector;

    const root_dir_sectors = ((@as(u32, root_entry_count) * 32) + (@as(u32, bytes_per_sector) - 1)) / bytes_per_sector;
    const first_data_sector = reserved_sector_count + (@as(u32, num_fats) * fat_size_sectors) + root_dir_sectors;
    if (first_data_sector >= total_sectors) return error.InvalidFatBootSector;

    const data_sectors = total_sectors - first_data_sector;
    const total_clusters = data_sectors / sectors_per_cluster;
    if (total_clusters < 1) return error.InvalidFatBootSector;

    const filesystem: Filesystem = if (total_clusters < 65525) .fat16 else .fat32;
    const partition_size = @as(u64, total_sectors) * bytes_per_sector;
    if (partition_size > size) return error.InvalidFatBootSector;

    return .{
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sector_count = reserved_sector_count,
        .num_fats = num_fats,
        .root_entry_count = root_entry_count,
        .total_sectors = total_sectors,
        .fat_size_sectors = fat_size_sectors,
        .root_dir_sectors = root_dir_sectors,
        .first_data_sector = first_data_sector,
        .total_clusters = total_clusters,
        .filesystem = filesystem,
    };
}

fn clusterAllocated(filesystem: Filesystem, fat: []const u8, cluster: u32) bool {
    return switch (filesystem) {
        .fat16 => blk: {
            const offset = cluster * 2;
            if (offset + 2 > fat.len) break :blk false;
            const value = readU16(fat[offset .. offset + 2]);
            break :blk value != 0;
        },
        .fat32 => blk: {
            const offset = cluster * 4;
            if (offset + 4 > fat.len) break :blk false;
            const value = readU32(fat[offset .. offset + 4]) & 0x0fffffff;
            break :blk value != 0;
        },
        else => false,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

pub const driver: driver_api.Driver = .{
    .mbr_types = &mbr_types,
    .detect = detect,
    .probe_region = probeRegion,
    .collect_ranges = collectRanges,
};

test "readBootSector detects fat16" {
    var bytes: [2048 * 512]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[11..13], 512, .little);
    bytes[13] = 4;
    std.mem.writeInt(u16, bytes[14..16], 1, .little);
    bytes[16] = 2;
    std.mem.writeInt(u16, bytes[17..19], 512, .little);
    std.mem.writeInt(u16, bytes[19..21], 2048, .little);
    std.mem.writeInt(u16, bytes[22..24], 8, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    const boot = try readBootSector(std.testing.io, &r, bytes.len);
    try std.testing.expectEqual(Filesystem.fat16, boot.filesystem);

    try std.testing.expect(detect(std.testing.io, &r));
}
