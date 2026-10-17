const std = @import("std");

const reader_mod = @import("../reader.zig");
const ondisk = @import("../ondisk.zig");
const types = @import("../types.zig");

pub const sector_size: usize = 512;
pub const partition_entry_offset: usize = 446;
pub const partition_entry_size: usize = 16;
pub const partition_entry_count: usize = 4;

/// The classic MBR sector. Partition entries start at the unaligned offset
/// 446, so every multi-byte field is declared `align(1)`.
const OnDiskMbr = extern struct {
    boot_code: [partition_entry_offset]u8,
    partitions: [partition_entry_count]Entry,
    signature: u16 align(1),

    const Entry = extern struct {
        status: u8,
        chs_first: [3]u8,
        partition_type: u8,
        chs_last: [3]u8,
        start_lba: u32 align(1),
        sector_count: u32 align(1),

        comptime {
            ondisk.expectLayout(Entry, partition_entry_size, .{ .partition_type = 4, .start_lba = 8, .sector_count = 12 });
        }
    };

    comptime {
        ondisk.expectLayout(OnDiskMbr, sector_size, .{ .partitions = partition_entry_offset, .signature = 510 });
    }
};

pub const PartitionSpan = struct {
    index: u8,
    partition_type: u8,
    start_offset: u64,
    size: u64,
};

pub fn looksLikeMbr(sector: *const [sector_size]u8) bool {
    const mbr = ondisk.decode(OnDiskMbr, sector);
    if (mbr.signature != 0xAA55) return false;

    for (mbr.partitions) |entry| {
        if (entry.partition_type != 0 and entry.sector_count != 0 and entry.start_lba != 0) return true;
    }
    return false;
}

pub fn collectPartitionSpans(allocator: std.mem.Allocator, sector: *const [sector_size]u8, image_size: u64) ![]PartitionSpan {
    var spans: std.ArrayList(PartitionSpan) = .empty;
    defer spans.deinit(allocator);

    const mbr = ondisk.decode(OnDiskMbr, sector);
    for (mbr.partitions, 0..) |entry, entry_index| {
        if (entry.partition_type == 0 or entry.sector_count == 0) continue;

        const start_offset = @as(u64, entry.start_lba) * sector_size;
        const size = @as(u64, entry.sector_count) * sector_size;
        const end_offset = std.math.add(u64, start_offset, size) catch return error.InvalidPartitionTable;
        if (start_offset >= image_size or end_offset > image_size) return error.InvalidPartitionTable;

        try spans.append(allocator, .{
            .index = @intCast(entry_index + 1),
            .partition_type = entry.partition_type,
            .start_offset = start_offset,
            .size = size,
        });
    }

    const result = try spans.toOwnedSlice(allocator);
    std.mem.sort(PartitionSpan, result, {}, lessByOffset);
    return result;
}

// Layout driver contract; see driver.zig.

pub const layout: types.Info.Layout = .mbr;

pub fn detect(io: std.Io, r: *const reader_mod.Reader) bool {
    if (r.size < sector_size) return false;

    var buffer: [sector_size]u8 = undefined;
    r.readExactlyAt(io, &buffer, 0) catch return false;
    return looksLikeMbr(&buffer);
}

pub fn collectSpans(allocator: std.mem.Allocator, io: std.Io, r: *const reader_mod.Reader) ![]PartitionSpan {
    var buffer: [sector_size]u8 = undefined;
    try r.readExactlyAt(io, &buffer, 0);
    return collectPartitionSpans(allocator, &buffer, r.size);
}

fn lessByOffset(_: void, lhs: PartitionSpan, rhs: PartitionSpan) bool {
    if (lhs.start_offset != rhs.start_offset) return lhs.start_offset < rhs.start_offset;
    return lhs.index < rhs.index;
}

test "looksLikeMbr detects active partition table" {
    var sector: [sector_size]u8 = @splat(0);
    sector[partition_entry_offset + 4] = 0x83;
    std.mem.writeInt(u32, sector[partition_entry_offset + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, sector[partition_entry_offset + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, sector[510..512], 0xAA55, .little);

    try std.testing.expect(looksLikeMbr(&sector));
}

test "partition spans are sorted by logical offset" {
    var sector: [sector_size]u8 = @splat(0);
    sector[partition_entry_offset + 4] = 0x83;
    std.mem.writeInt(u32, sector[partition_entry_offset + 8 ..][0..4], 4096, .little);
    std.mem.writeInt(u32, sector[partition_entry_offset + 12 ..][0..4], 8, .little);
    const second = partition_entry_offset + partition_entry_size;
    sector[second + 4] = 0x0c;
    std.mem.writeInt(u32, sector[second + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, sector[second + 12 ..][0..4], 8, .little);
    std.mem.writeInt(u16, sector[510..512], 0xAA55, .little);

    const spans = try collectPartitionSpans(std.testing.allocator, &sector, 5000 * sector_size);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(u8, 2), spans[0].index);
    try std.testing.expectEqual(@as(u8, 1), spans[1].index);
}

test "layout driver detects an mbr image through a buffer reader" {
    var bytes: [2048 * 512]u8 = @splat(0);
    bytes[446 + 4] = 0x06;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], 1, .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], 1024, .little);
    std.mem.writeInt(u16, bytes[510..512], 0xAA55, .little);

    var source = reader_mod.Buffer.init(&bytes);
    const r = source.reader();
    const io = std.testing.io;

    try std.testing.expect(detect(io, &r));

    const spans = try collectSpans(std.testing.allocator, io, &r);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(u64, 512), spans[0].start_offset);
}
