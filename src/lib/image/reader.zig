const std = @import("std");

/// One bounded, random-access view over image bytes.
///
/// Every layout and filesystem parser takes a `Reader` plus a region, so one
/// parser serves both the file pipeline and the in-memory pipeline.
///
/// The type is a thin vtable. The two built-in sources (`Buffer`, `FileRegion`)
/// are non-owning views and need no allocation; owning sources may supply an
/// optional `deinit_fn`.
pub const Reader = struct {
    /// Every source reads from memory or a file, so this set is closed.
    pub const ReadError = std.Io.File.ReadPositionalError || error{RangeOverflow};
    pub const ReadExactError = ReadError || error{ImageTruncated};

    context: *anyopaque,
    /// Total readable length in bytes.
    size: u64,
    read_at_fn: *const fn (context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) ReadError!usize,
    deinit_fn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) void = null,

    pub fn readAt(self: *const Reader, io: std.Io, buffer: []u8, offset: u64) ReadError!usize {
        if (buffer.len == 0) return 0;
        if (offset >= self.size) return 0;
        return self.read_at_fn(self.context, io, buffer, offset);
    }

    /// Reads the full buffer or fails with `ImageTruncated`.
    pub fn readExactlyAt(self: *const Reader, io: std.Io, buffer: []u8, offset: u64) ReadExactError!void {
        var completed: usize = 0;
        while (completed < buffer.len) {
            const count = try self.readAt(io, buffer[completed..], offset + completed);
            if (count == 0) return error.ImageTruncated;
            completed += count;
        }
    }

    pub fn readU16LeAt(self: *const Reader, io: std.Io, offset: u64) ReadExactError!u16 {
        var bytes: [2]u8 = undefined;
        try self.readExactlyAt(io, &bytes, offset);
        return std.mem.readInt(u16, &bytes, .little);
    }

    pub fn readU32LeAt(self: *const Reader, io: std.Io, offset: u64) ReadExactError!u32 {
        var bytes: [4]u8 = undefined;
        try self.readExactlyAt(io, &bytes, offset);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn readU64LeAt(self: *const Reader, io: std.Io, offset: u64) ReadExactError!u64 {
        var bytes: [8]u8 = undefined;
        try self.readExactlyAt(io, &bytes, offset);
        return std.mem.readInt(u64, &bytes, .little);
    }

    pub fn deinit(self: *const Reader, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |deinit_fn| deinit_fn(self.context, allocator);
    }
};

/// A reader over bytes already held in memory. Non-owning.
pub const Buffer = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Buffer {
        return .{ .bytes = bytes };
    }

    pub fn reader(self: *Buffer) Reader {
        return .{
            .context = self,
            .size = self.bytes.len,
            .read_at_fn = readAt,
        };
    }

    fn readAt(context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) Reader.ReadError!usize {
        _ = io;
        const self: *Buffer = @ptrCast(@alignCast(context));
        if (offset >= self.bytes.len) return 0;
        const available = self.bytes.len - @as(usize, @intCast(offset));
        const count = @min(buffer.len, available);
        const start: usize = @intCast(offset);
        @memcpy(buffer[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

/// A reader over a byte interval of an open file. Non-owning.
pub const FileRegion = struct {
    io: std.Io,
    file: std.Io.File,
    base_offset: u64 = 0,
    length: u64,

    pub fn init(io: std.Io, file: std.Io.File, base_offset: u64, length: u64) FileRegion {
        return .{ .io = io, .file = file, .base_offset = base_offset, .length = length };
    }

    pub fn reader(self: *FileRegion) Reader {
        return .{
            .context = self,
            .size = self.length,
            .read_at_fn = readAt,
        };
    }

    fn readAt(context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) Reader.ReadError!usize {
        const self: *FileRegion = @ptrCast(@alignCast(context));
        if (offset >= self.length) return 0;
        const remaining = self.length - offset;
        const clipped = if (buffer.len > remaining) buffer[0..@intCast(remaining)] else buffer;
        const absolute_offset = std.math.add(u64, self.base_offset, offset) catch return error.RangeOverflow;
        return self.file.readPositional(io, &.{clipped}, absolute_offset);
    }
};

/// A bounded view over part of another reader. Non-owning.
///
/// Offset 0 of the slice maps to `base_offset` of the parent reader. This is
/// how whole-image parsers hand a partition region to a filesystem driver.
pub const Slice = struct {
    parent: *const Reader,
    base_offset: u64,
    length: u64,

    pub fn init(parent: *const Reader, base_offset: u64, length: u64) Slice {
        return .{ .parent = parent, .base_offset = base_offset, .length = length };
    }

    pub fn reader(self: *Slice) Reader {
        return .{
            .context = self,
            .size = self.length,
            .read_at_fn = readAt,
        };
    }

    fn readAt(context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) Reader.ReadError!usize {
        const self: *Slice = @ptrCast(@alignCast(context));
        if (offset >= self.length) return 0;
        const remaining = self.length - offset;
        const clipped = if (buffer.len > remaining) buffer[0..@intCast(remaining)] else buffer;
        const parent_offset = std.math.add(u64, self.base_offset, offset) catch return error.RangeOverflow;
        return self.parent.readAt(io, clipped, parent_offset);
    }
};

test "buffer reader serves aligned and unaligned reads" {
    var source = Buffer.init("abcdefgh");
    const r = source.reader();

    var four: [4]u8 = undefined;
    try r.readExactlyAt(std.testing.io, &four, 2);
    try std.testing.expectEqualStrings("cdef", &four);

    var tail: [5]u8 = undefined;
    const short = try r.readAt(std.testing.io, &tail, 5);
    try std.testing.expectEqual(@as(usize, 3), short);
    try std.testing.expectEqualStrings("fgh", tail[0..3]);

    try std.testing.expectError(error.ImageTruncated, r.readExactlyAt(std.testing.io, &four, 6));
}

test "file region reader bounds reads to its interval" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "region.img", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "0123456789");
    try file.sync(io);

    var region = FileRegion.init(io, file, 4, 4);
    const r = region.reader();

    var bytes: [8]u8 = undefined;
    try r.readExactlyAt(io, bytes[0..4], 0);
    try std.testing.expectEqualStrings("4567", bytes[0..4]);

    const short = try r.readAt(io, bytes[0..8], 2);
    try std.testing.expectEqual(@as(usize, 2), short);

    try std.testing.expectEqual(@as(usize, 0), try r.readAt(io, bytes[0..1], 4));
}

test "slice reader bounds a parent region" {
    var source = Buffer.init("0123456789");
    const parent = source.reader();
    var slice = Slice.init(&parent, 3, 4);
    const r = slice.reader();

    var bytes: [4]u8 = undefined;
    try r.readExactlyAt(std.testing.io, &bytes, 0);
    try std.testing.expectEqualStrings("3456", &bytes);

    try std.testing.expectEqual(@as(usize, 2), try r.readAt(std.testing.io, bytes[0..4], 2));
    try std.testing.expectEqual(@as(usize, 0), try r.readAt(std.testing.io, bytes[0..1], 4));
}

test "reader helpers decode little-endian integers" {
    var source = Buffer.init(&.{ 0x34, 0x12, 0x78, 0x56, 0x00, 0x00, 0xef, 0xbe });
    const r = source.reader();
    const io = std.testing.io;

    try std.testing.expectEqual(@as(u16, 0x1234), try r.readU16LeAt(io, 0));
    try std.testing.expectEqual(@as(u32, 0x56781234), try r.readU32LeAt(io, 0));
    try std.testing.expectEqual(@as(u64, 0xbeef000056781234), try r.readU64LeAt(io, 0));
}
