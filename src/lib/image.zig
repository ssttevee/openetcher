const std = @import("std");

const fs = @import("fs.zig");
const root = @import("../root.zig");

pub const ByteRange = root.ByteRange;
pub const FlashPlan = root.FlashPlan;

pub const Info = struct {
    image_size: u64,
    layout: Layout,
    filesystem: ?Filesystem = null,
    block_size: ?u32 = null,
    used_bytes: ?u64 = null,
    skipped_bytes: ?u64 = null,
    range_count: ?usize = null,
    partitions: []const PartitionInfo = &.{},

    pub const Layout = enum {
        raw_ext4,
        mbr,
    };

    pub const Filesystem = fs.Filesystem;

    pub const PartitionInfo = struct {
        index: u8,
        start_offset: u64,
        size: u64,
        partition_type: u8,
        filesystem: Filesystem,
        supported: bool,
        reason: ?[]const u8 = null,
        block_size: ?u32 = null,
        used_bytes: ?u64 = null,
        skipped_bytes: ?u64 = null,
        range_count: ?usize = null,
    };

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.partitions) |partition| {
            if (partition.reason) |reason| allocator.free(reason);
        }
        if (self.partitions.len > 0) allocator.free(self.partitions);
    }

    pub fn firstUnsupportedPartition(self: @This()) ?PartitionInfo {
        for (self.partitions) |partition| {
            if (!partition.supported) return partition;
        }
        return null;
    }
};

const sector_size: usize = 512;

pub fn probeImage(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !Info {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    return probeImageFromFile(allocator, io, &file, image_path);
}

pub fn planImageFlash(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) !FlashPlan {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    const image_size = try file.length(io);
    var mbr_sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &mbr_sector, 0);
    if (count != mbr_sector.len) return error.InvalidImage;

    if (!looksLikeMbr(&mbr_sector)) {
        return .{
            .image_size = image_size,
            .ranges = try fs.ext4.collectExt4Ranges(allocator, io, image_path),
        };
    }

    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);
    var occupied: std.ArrayList(ByteRange) = .empty;
    defer occupied.deinit(allocator);

    for (0..4) |entry_index| {
        const entry_offset = 446 + (entry_index * 16);
        const entry = mbr_sector[entry_offset .. entry_offset + 16];
        const partition_type = entry[4];
        const start_lba = readU32(entry[8..12]);
        const size_lba = readU32(entry[12..16]);

        if (partition_type == 0 or size_lba == 0) continue;

        const start_offset = @as(u64, start_lba) * sector_size;
        const size = @as(u64, size_lba) * sector_size;
        const end_offset = std.math.add(u64, start_offset, size) catch return error.InvalidPartitionTable;
        if (start_offset >= image_size or end_offset > image_size) return error.InvalidPartitionTable;
        try occupied.append(allocator, .{ .offset = start_offset, .length = size });

        const partition = classifyPartition(allocator, io, &file, @intCast(entry_index + 1), partition_type, start_offset, size);
        defer if (partition.reason) |reason| allocator.free(reason);

        if (!partition.supported) {
            if (partition.filesystem == .empty) continue;
            return error.UnsupportedPartitionFilesystem;
        }

        switch (partition.filesystem) {
            .ext4 => {
                const ext4_ranges = try fs.ext4.collectExt4RangesInRegion(allocator, io, &file, start_offset, size);
                defer allocator.free(ext4_ranges);
                try ranges.appendSlice(allocator, ext4_ranges);
            },
            .fat16, .fat32 => {
                const fat_ranges = try fs.fat.collectFatRangesInRegion(allocator, io, &file, start_offset, size);
                defer allocator.free(fat_ranges);
                try ranges.appendSlice(allocator, fat_ranges);
            },
            .squashfs => {
                const squashfs_ranges = try fs.squashfs.collectSquashfsRangesInRegion(allocator, io, &file, start_offset, size);
                defer allocator.free(squashfs_ranges);
                try ranges.appendSlice(allocator, squashfs_ranges);
            },
            else => return error.UnsupportedPartitionFilesystem,
        }
    }

    try appendGapRanges(allocator, &ranges, occupied.items, image_size);

    const normalized_ranges = try root.normalizeRanges(allocator, ranges.items);
    errdefer allocator.free(normalized_ranges);

    return .{
        .image_size = image_size,
        .ranges = normalized_ranges,
    };
}

fn probeImageFromFile(allocator: std.mem.Allocator, io: std.Io, file: *std.Io.File, image_path: []const u8) !Info {
    const image_size = try file.length(io);
    var mbr_sector: [sector_size]u8 = undefined;
    const count = try file.readPositionalAll(io, &mbr_sector, 0);
    if (count != mbr_sector.len) return error.InvalidImage;

    if (!looksLikeMbr(&mbr_sector)) {
        return fs.ext4.probeExt4Image(allocator, io, image_path);
    }

    var partitions: std.ArrayList(Info.PartitionInfo) = .empty;
    defer partitions.deinit(allocator);

    for (0..4) |entry_index| {
        const entry_offset = 446 + (entry_index * 16);
        const entry = mbr_sector[entry_offset .. entry_offset + 16];
        const partition_type = entry[4];
        const start_lba = readU32(entry[8..12]);
        const size_lba = readU32(entry[12..16]);

        if (partition_type == 0 or size_lba == 0) continue;

        const start_offset = @as(u64, start_lba) * sector_size;
        const size = @as(u64, size_lba) * sector_size;
        const end_offset = std.math.add(u64, start_offset, size) catch return error.InvalidPartitionTable;
        if (start_offset >= image_size or end_offset > image_size) return error.InvalidPartitionTable;

        const partition = classifyPartition(allocator, io, file, @intCast(entry_index + 1), partition_type, start_offset, size);
        try partitions.append(allocator, partition);
    }

    return .{
        .image_size = image_size,
        .layout = .mbr,
        .partitions = try partitions.toOwnedSlice(allocator),
    };
}

fn classifyPartition(allocator: std.mem.Allocator, io: std.Io, file: *std.Io.File, index: u8, partition_type: u8, start_offset: u64, size: u64) Info.PartitionInfo {
    if (partition_type == 0x0b or partition_type == 0x0c or partition_type == 0x0e) {
        const probed = fs.fat.probeFatPartition(allocator, io, file, start_offset, size) catch |err| {
            const reason = std.fmt.allocPrint(allocator, "fat probe failed: {t}", .{err}) catch null;
            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = .unknown,
                .supported = false,
                .reason = reason,
            };
        };

        var partition = probed;
        partition.index = index;
        partition.partition_type = partition_type;
        return partition;
    }

    if (partition_type == 0x83) {
        const linux_kind = classifyLinuxPartition(io, file, start_offset) catch .linux_unknown;
        if (linux_kind != .linux_unknown) {
            if (linux_kind == .squashfs) {
                const probed = fs.squashfs.probeSquashfsPartition(io, file, start_offset, size) catch |err| {
                    const reason = std.fmt.allocPrint(allocator, "squashfs probe failed: {t}", .{err}) catch null;
                    return .{
                        .index = index,
                        .start_offset = start_offset,
                        .size = size,
                        .partition_type = partition_type,
                        .filesystem = .squashfs,
                        .supported = false,
                        .reason = reason,
                    };
                };

                var partition = probed;
                partition.index = index;
                partition.partition_type = partition_type;
                return partition;
            }

            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = linux_kind,
                .supported = false,
                .reason = switch (linux_kind) {
                    .empty => allocator.dupe(u8, "partition appears empty") catch null,
                    else => null,
                },
            };
        }

        const probed = fs.ext4.probeExt4Partition(allocator, io, file, start_offset, size) catch |err| {
            const reason = std.fmt.allocPrint(allocator, "ext4 probe failed: {t}", .{err}) catch null;
            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = .linux_unknown,
                .supported = false,
                .reason = reason,
            };
        };

        var partition = probed;
        partition.index = index;
        partition.partition_type = partition_type;
        return partition;
    }

    return .{
        .index = index,
        .start_offset = start_offset,
        .size = size,
        .partition_type = partition_type,
        .filesystem = .unknown,
        .supported = false,
        .reason = allocator.dupe(u8, "unknown partition type") catch null,
    };
}

fn classifyLinuxPartition(io: std.Io, file: *std.Io.File, start_offset: u64) !Info.Filesystem {
    var header: [4096]u8 = undefined;
    const count = try file.readPositionalAll(io, &header, start_offset);
    if (count == 0) return .empty;

    if (std.mem.eql(u8, header[0..4], "hsqs")) return .squashfs;
    if (isAllZero(header[0..count])) return .empty;
    return .linux_unknown;
}

fn isAllZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
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

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

test "probeImage detects mbr partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** (8192 * 512);
    bytes[446 + 4] = 0x0c;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    bytes[462 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[462 + 8 ..][0..4], 4096, .little);
    std.mem.writeInt(u32, bytes[462 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);

    const fat_offset = 2048 * 512;
    std.mem.writeInt(u16, bytes[fat_offset + 11 ..][0..2], 512, .little);
    bytes[fat_offset + 13] = 4;
    std.mem.writeInt(u16, bytes[fat_offset + 14 ..][0..2], 1, .little);
    bytes[fat_offset + 16] = 2;
    std.mem.writeInt(u16, bytes[fat_offset + 17 ..][0..2], 512, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 19 ..][0..2], 1024, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 22 ..][0..2], 8, .little);
    std.mem.writeInt(u16, bytes[fat_offset + 510 ..][0..2], 0xAA55, .little);

    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const info = try probeImageFromFile(std.testing.allocator, io, &file, "unused.img");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Info.Layout, .mbr), info.layout);
    try std.testing.expectEqual(@as(usize, 2), info.partitions.len);
    try std.testing.expectEqual(@as(Info.Filesystem, .fat16), info.partitions[0].filesystem);
    try std.testing.expectEqual(true, info.partitions[0].supported);
    try std.testing.expectEqual(@as(Info.Filesystem, .empty), info.partitions[1].filesystem);
    try std.testing.expectEqual(false, info.partitions[1].supported);
}

test "planImageFlash rejects unsupported mbr partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "disk.img", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{0} ** (4096 * 512);
    bytes[446 + 4] = 0x0c;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);
    try file.writeStreamingAll(io, &bytes);
    try file.sync(io);

    const path = try tmp.dir.realPathFileAlloc(io, "disk.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.UnsupportedPartitionFilesystem, planImageFlash(std.testing.allocator, io, path));
}

fn appendGapRanges(allocator: std.mem.Allocator, ranges: *std.ArrayList(ByteRange), occupied_ranges: []const ByteRange, image_size: u64) !void {
    const normalized_occupied = try root.normalizeRanges(allocator, occupied_ranges);
    defer allocator.free(normalized_occupied);

    var cursor: u64 = 0;
    for (normalized_occupied) |segment| {
        if (cursor < segment.offset) {
            try ranges.append(allocator, .{ .offset = cursor, .length = segment.offset - cursor });
        }
        cursor = segment.end();
    }
    if (cursor < image_size) {
        try ranges.append(allocator, .{ .offset = cursor, .length = image_size - cursor });
    }
}

test "appendGapRanges preserves non-partition disk gaps" {
    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(std.testing.allocator);

    const occupied = [_]ByteRange{
        .{ .offset = 4096, .length = 2048 },
        .{ .offset = 12288, .length = 4096 },
    };

    try appendGapRanges(std.testing.allocator, &ranges, &occupied, 20480);
    try std.testing.expectEqual(@as(usize, 3), ranges.items.len);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 0, .length = 4096 }, ranges.items[0]);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 6144, .length = 6144 }, ranges.items[1]);
    try std.testing.expectEqualDeep(ByteRange{ .offset = 16384, .length = 4096 }, ranges.items[2]);
}
