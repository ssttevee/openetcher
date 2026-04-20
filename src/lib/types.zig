const std = @import("std");

pub const ByteRange = struct {
    offset: u64,
    length: u64,

    pub fn end(self: @This()) u64 {
        return std.math.add(u64, self.offset, self.length) catch unreachable;
    }
};

pub const UnsupportedPolicy = enum {
    fail,
};

pub const VerifyMode = enum {
    none,
    written,
};

pub const FlashOptions = struct {
    block_size: usize = 1024 * 1024,
    verify: VerifyMode = .written,
    unsupported: UnsupportedPolicy = .fail,
};

pub const ImageInfo = struct {
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

    pub const Filesystem = enum {
        ext4,
        fat16,
        fat32,
        squashfs,
        empty,
        linux_unknown,
        unknown,
    };

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

pub const FlashReport = struct {
    image_size: u64,
    bytes_read: u64,
    bytes_written: u64,
    bytes_skipped: u64,
    range_count: usize,
};

pub const FlashPlan = struct {
    image_size: u64,
    ranges: []ByteRange,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
    }
};
