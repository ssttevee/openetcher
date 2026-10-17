const std = @import("std");

const contract = @import("../../contract.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");
const mbr_mod = @import("mbr.zig");

/// One partition interval inside a disk-layout image.
/// `partition_type` is MBR-speak today; GPT reuses it with its own GUID
/// mapping or leaves 0 and relies on content sniffing.
pub const Span = mbr_mod.PartitionSpan;

const Reader = reader_mod.Reader;

/// Disk-layout drivers, in detection precedence.
///
/// Add a container format (for example GPT): create one module satisfying
/// the contract below, then list it here. The analyzer in image.zig turns
/// each layout's spans plus the filesystem drivers into an `Analysis`.
///
/// Required declarations:
///   `pub const layout: Layout` - tag reported for images in this layout
///   `pub fn detect(std.Io, *const Reader) bool` - cheap, allocation-free
///       signature check against the whole image
///   `pub fn collectSpans(Allocator, std.Io, *const Reader) ![]Span` -
///       partition spans with absolute offsets, sorted by offset
pub const drivers = .{
    mbr_mod,
};

comptime {
    var seen: std.EnumSet(types.Info.Layout) = .empty;
    for (drivers) |L| {
        validate(L);
        if (seen.contains(L.layout)) @compileError("two layout drivers report " ++ @tagName(L.layout));
        seen.insert(L.layout);
    }
}

/// Checks `L` against the layout contract. Generic callers invoke it first
/// so a broken driver reports the contract, not a downstream type error.
pub fn validate(comptime L: type) void {
    contract.expectDecls(L, "layout driver", &.{ "layout", "detect", "collectSpans" });
    _ = @as(types.Info.Layout, L.layout);
    contract.expectFn(L, "detect", &.{ std.Io, *const Reader }, bool);
    contract.expectFn(L, "collectSpans", &.{ std.mem.Allocator, std.Io, *const Reader }, []Span);
}

test "layout registry exposes the mbr driver" {
    try std.testing.expectEqual(types.Info.Layout.mbr, drivers[0].layout);
}
