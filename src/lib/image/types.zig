const std = @import("std");

const fs = @import("fs.zig");
const source = @import("source.zig");

pub const Info = struct {
    image_size: u64,
    encoded_size: ?u64 = null,
    compression: source.Compression = .none,
    layout: Layout,
    filesystem: ?Filesystem = null,
    block_size: ?u32 = null,
    used_bytes: ?u64 = null,
    skipped_bytes: ?u64 = null,
    range_count: ?usize = null,
    partitions: []const PartitionInfo = &.{},

    pub const Layout = enum {
        raw_ext4,
        raw_iso9660,
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
