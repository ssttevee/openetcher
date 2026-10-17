const std = @import("std");

const fs = @import("fs.zig");
const fs_driver = @import("fs/driver.zig");
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

    /// What a filesystem driver learns by probing a region. Partition
    /// placement comes from the layout, so the analyzer adds it.
    pub const Probe = struct {
        filesystem: Filesystem,
        block_size: ?u32 = null,
        used_bytes: ?u64 = null,
        skipped_bytes: ?u64 = null,
        range_count: ?usize = null,
    };

    pub const PartitionInfo = struct {
        index: u8,
        start_offset: u64,
        size: u64,
        partition_type: u8,
        filesystem: Filesystem,
        supported: bool,
        reason: ?Reason = null,
        block_size: ?u32 = null,
        used_bytes: ?u64 = null,
        skipped_bytes: ?u64 = null,
        range_count: ?usize = null,

        /// A supported partition at the given place, described by `probe`.
        pub fn probed(probe: Probe, index: u8, start_offset: u64, size: u64, partition_type: u8) PartitionInfo {
            return .{
                .index = index,
                .start_offset = start_offset,
                .size = size,
                .partition_type = partition_type,
                .filesystem = probe.filesystem,
                .supported = true,
                .block_size = probe.block_size,
                .used_bytes = probe.used_bytes,
                .skipped_bytes = probe.skipped_bytes,
                .range_count = probe.range_count,
            };
        }
    };

    /// Why a partition cannot be planned. Kept as values and formatted only
    /// when shown, so recording a reason never allocates.
    pub const Reason = union(enum) {
        /// The partition starts with zeros: there is nothing to copy.
        empty,
        /// No driver handles the partition's MBR type.
        unknown_type,
        /// A driver claimed the partition but could not read it.
        driver_failed: DriverFailure,

        pub const DriverFailure = struct {
            /// The driver's `name`.
            driver: []const u8,
            stage: enum { probe, range_collection },
            err: fs_driver.Error,
        };

        pub fn format(self: Reason, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .empty => try writer.writeAll("partition appears empty"),
                .unknown_type => try writer.writeAll("unknown partition type"),
                .driver_failed => |failure| try writer.print("{s} {s} failed: {t}", .{
                    failure.driver,
                    switch (failure.stage) {
                        .probe => "probe",
                        .range_collection => "range collection",
                    },
                    failure.err,
                }),
            }
        }

        /// Serializes as the text `format` produces.
        pub fn jsonStringify(self: *const Reason, jw: anytype) !void {
            // Driver names and error names are short; this cannot fill.
            var buffer: [256]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&buffer, "{f}", .{self.*}) catch unreachable);
        }
    };

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.partitions.len > 0) allocator.free(self.partitions);
    }

    pub fn firstUnsupportedPartition(self: @This()) ?PartitionInfo {
        for (self.partitions) |partition| {
            if (!partition.supported) return partition;
        }
        return null;
    }
};

test "partition reasons format without allocating" {
    var buffer: [128]u8 = undefined;
    const failure: Info.Reason = .{ .driver_failed = .{ .driver = "ext4", .stage = .range_collection, .err = error.InvalidExt4GroupDescriptor } };
    try std.testing.expectEqualStrings("ext4 range collection failed: InvalidExt4GroupDescriptor", try std.fmt.bufPrint(&buffer, "{f}", .{failure}));
    try std.testing.expectEqualStrings("partition appears empty", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Info.Reason, .empty)}));

    var json: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(@as(Info.Reason, .unknown_type), .{}, &json);
    try std.testing.expectEqualStrings("\"unknown partition type\"", json.buffered());
}
