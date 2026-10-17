const std = @import("std");

const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

pub const sector_size: usize = 512;
pub const partition_entry_offset: usize = 446;
pub const partition_entry_size: usize = 16;
pub const partition_entry_count: usize = 4;

pub const PartitionSpan = struct {
    index: u8,
    partition_type: u8,
    start_offset: u64,
    size: u64,
};

pub fn looksLikeMbr(sector: *const [sector_size]u8) bool {
    if (readU16(sector[510..512]) != 0xAA55) return false;

    for (0..partition_entry_count) |entry_index| {
        const entry_offset = partition_entry_offset + (entry_index * partition_entry_size);
        const entry = sector[entry_offset .. entry_offset + partition_entry_size];
        const partition_type = entry[4];
        const start_lba = readU32(entry[8..12]);
        const size_lba = readU32(entry[12..16]);
        if (partition_type != 0 and size_lba != 0 and start_lba != 0) return true;
    }

    return false;
}

pub fn collectPartitionSpans(allocator: std.mem.Allocator, sector: *const [sector_size]u8, image_size: u64) ![]PartitionSpan {
    var spans: std.ArrayList(PartitionSpan) = .empty;
    defer spans.deinit(allocator);

    for (0..partition_entry_count) |entry_index| {
        const entry_offset = partition_entry_offset + (entry_index * partition_entry_size);
        const entry = sector[entry_offset .. entry_offset + partition_entry_size];
        const partition_type = entry[4];
        const start_lba = readU32(entry[8..12]);
        const size_lba = readU32(entry[12..16]);

        if (partition_type == 0 or size_lba == 0) continue;

        const start_offset = @as(u64, start_lba) * sector_size;
        const size = @as(u64, size_lba) * sector_size;
        const end_offset = std.math.add(u64, start_offset, size) catch return error.InvalidPartitionTable;
        if (start_offset >= image_size or end_offset > image_size) return error.InvalidPartitionTable;

        try spans.append(allocator, .{
            .index = @intCast(entry_index + 1),
            .partition_type = partition_type,
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

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
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
