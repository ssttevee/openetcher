const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");
const mbr_mod = @import("mbr.zig");

/// One partition interval inside a disk-layout image.
/// `partition_type` is MBR-speak today; GPT reuses it with its own GUID
/// mapping or leaves 0 and relies on content sniffing.
pub const Span = mbr_mod.PartitionSpan;

/// Contract every disk-layout parser satisfies.
///
/// Add a container format (for example GPT): create one module exposing
/// `pub const driver`, then list it in `drivers`. The analyzer in image.zig
/// owns assembly; a new layout also needs one branch there that turns spans
/// plus filesystem drivers into an `Analysis`.
pub const Driver = struct {
    id: types.Info.Layout,
    /// Cheap signature check against the whole-image reader. Must not allocate.
    detect: *const fn (io: std.Io, r: *const reader_mod.Reader) bool,
    /// Collects partition spans with absolute offsets. Empty for layouts
    /// without partitions.
    collect_spans: *const fn (allocator: std.mem.Allocator, io: std.Io, r: *const reader_mod.Reader) anyerror![]Span,
};

/// Registry order is detection precedence among partitioned layouts.
pub const drivers = [_]Driver{
    @import("mbr.zig").driver,
};

comptime {
    _ = &mbr_mod;
}

test "layout registry exposes the mbr driver" {
    try std.testing.expectEqual(types.Info.Layout.mbr, drivers[0].id);
}
