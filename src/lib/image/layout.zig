const std = @import("std");
const range = @import("../range.zig");
const fs = @import("fs.zig");

pub const ByteRange = range.ByteRange;
pub const mbr = @import("layout/mbr.zig");

pub const Layout = enum {
    raw_ext4,
    raw_iso9660,
    mbr,
};

pub const Confidence = enum {
    none,
    possible,
    likely,
    exact,
};

pub const PartitionProbe = struct {
    index: u8,
    offset: u64,
    length: u64,
    partition_type: u8,
    filesystem: ?fs.Filesystem = null,
};

pub const ProbeResult = struct {
    layout: Layout,
    filesystem: ?fs.Filesystem,
    confidence: Confidence,
    required_image_size: ?u64,
    partitions: []PartitionProbe,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.partitions.len != 0) allocator.free(self.partitions);
    }
};
