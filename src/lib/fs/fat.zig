const std = @import("std");

const root = @import("../../root.zig");

pub const ByteRange = root.ByteRange;
pub const PartitionInfo = root.ImageInfo.PartitionInfo;
pub const Filesystem = root.ImageInfo.Filesystem;

const sector_size: u64 = 512;

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
    boot_sector_offset: u64,

    fn clusterFirstSector(self: @This(), cluster: u32) u64 {
        const data_sector = self.first_data_sector + ((cluster - 2) * self.sectors_per_cluster);
        return self.boot_sector_offset + (@as(u64, data_sector) * self.bytes_per_sector);
    }

    fn clusterLength(self: @This()) u64 {
        return @as(u64, self.bytes_per_sector) * self.sectors_per_cluster;
    }

    fn fatOffset(self: @This(), fat_index: u8) u64 {
        const sector = self.reserved_sector_count + (@as(u32, fat_index) * self.fat_size_sectors);
        return self.boot_sector_offset + (@as(u64, sector) * self.bytes_per_sector);
    }

    fn fatLength(self: @This()) u64 {
        return @as(u64, self.fat_size_sectors) * self.bytes_per_sector;
    }
};

pub fn probeFatPartition(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, start_offset: u64, size: u64) !PartitionInfo {
    const boot = try readBootSector(io, file, start_offset, size);
    const ranges = try collectFatRangesInRegion(allocator, io, file, start_offset, size);
    defer allocator.free(ranges);

    var used_bytes: u64 = 0;
    for (ranges) |segment| used_bytes += segment.length;

    return .{
        .index = 0,
        .start_offset = start_offset,
        .size = size,
        .partition_type = 0,
        .filesystem = boot.filesystem,
        .supported = true,
        .block_size = @intCast(boot.clusterLength()),
        .used_bytes = used_bytes,
        .skipped_bytes = size - used_bytes,
        .range_count = ranges.len,
    };
}

pub fn collectFatRangesInRegion(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, start_offset: u64, size: u64) ![]ByteRange {
    const boot = try readBootSector(io, file, start_offset, size);

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);

    try ranges.append(allocator, .{
        .offset = start_offset,
        .length = @as(u64, boot.first_data_sector) * boot.bytes_per_sector,
    });

    const fat = try allocator.alloc(u8, @intCast(boot.fatLength()));
    defer allocator.free(fat);
    const fat_count = try file.readPositionalAll(io, fat, boot.fatOffset(0));
    if (fat_count != fat.len) return error.InvalidFatBootSector;

    var cluster: u32 = 2;
    while (cluster < boot.total_clusters + 2) : (cluster += 1) {
        if (!clusterAllocated(boot.filesystem, fat, cluster)) continue;
        try ranges.append(allocator, .{
            .offset = boot.clusterFirstSector(cluster),
            .length = boot.clusterLength(),
        });
    }

    return root.normalizeRanges(allocator, ranges.items);
}

fn readBootSector(io: std.Io, file: std.Io.File, start_offset: u64, size: u64) !BootSector {
    var sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &sector, start_offset);
    if (count != sector.len) return error.InvalidFatBootSector;
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

    const root_dir_sectors = ((@as(u32, root_entry_count) * 32) + (bytes_per_sector - 1)) / bytes_per_sector;
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
        .boot_sector_offset = start_offset,
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

test "readBootSector detects fat16" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "fat.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** (2048 * 512);
    std.mem.writeInt(u16, bytes[11..13], 512, .little);
    bytes[13] = 4;
    std.mem.writeInt(u16, bytes[14..16], 1, .little);
    bytes[16] = 2;
    std.mem.writeInt(u16, bytes[17..19], 512, .little);
    std.mem.writeInt(u16, bytes[19..21], 2048, .little);
    std.mem.writeInt(u16, bytes[22..24], 8, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);
    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const boot = try readBootSector(io, file, 0, bytes.len);
    try std.testing.expectEqual(Filesystem.fat16, boot.filesystem);
}
