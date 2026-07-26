const std = @import("std");
const range = @import("../range.zig");

pub const ByteRange = range.ByteRange;

pub const Filesystem = enum {
    ext4,
    fat16,
    fat32,
    iso9660,
    squashfs,
    empty,
    linux_unknown,
    unknown,
};

pub const Purpose = enum {
    layout,
    filesystem_probe,
    metadata,
    allocation,
    data,
};

pub const ReadRequest = struct {
    offset: u64,
    length: usize,
    purpose: Purpose,
};

pub const Analysis = struct {
    image_size: u64,
    ranges: []ByteRange,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
    }
};

pub const Analyzer = struct {
    context: *anyopaque,
    next_request_fn: *const fn (context: *anyopaque) anyerror!?ReadRequest,
    consume_fn: *const fn (context: *anyopaque, request: ReadRequest, bytes: []const u8) anyerror!void,
    finish_fn: *const fn (context: *anyopaque, image_size: u64) anyerror!Analysis,
    position: u64 = 0,

    pub fn nextRequest(self: *@This()) !?ReadRequest {
        const request = try self.next_request_fn(self.context);
        if (request) |item| {
            if (item.offset < self.position) return error.BackwardStreamRequest;
        }
        return request;
    }

    pub fn consume(self: *@This(), request: ReadRequest, bytes: []const u8) !void {
        if (request.offset < self.position) return error.BackwardStreamRequest;
        if (bytes.len != request.length) return error.UnexpectedEndOfImage;
        try self.consume_fn(self.context, request, bytes);
        self.position = std.math.add(u64, request.offset, request.length) catch return error.RangeOverflow;
    }

    pub fn finish(self: *@This(), image_size: u64) !Analysis {
        return self.finish_fn(self.context, image_size);
    }
};

pub const ext4 = @import("fs/ext4.zig");
pub const fat = @import("fs/fat.zig");
pub const iso9660 = @import("fs/iso9660.zig");
pub const squashfs = @import("fs/squashfs.zig");
