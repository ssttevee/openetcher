const std = @import("std");

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
    for ([_][]const u8{ "layout", "detect", "collectSpans" }) |decl| {
        if (!@hasDecl(L, decl)) @compileError(@typeName(L) ++ ": layout driver is missing `pub " ++ decl ++ "`");
    }
    _ = @as(types.Info.Layout, L.layout);
    _ = @as(fn (std.Io, *const Reader) bool, L.detect);
    const collect = @typeInfo(@TypeOf(L.collectSpans)).@"fn";
    if (collect.param_types.len != 3 or collect.param_types[0] != std.mem.Allocator or collect.param_types[1] != std.Io or collect.param_types[2] != *const Reader or
        @typeInfo(collect.return_type.?).error_union.payload != []Span)
    {
        @compileError(@typeName(L) ++ ".collectSpans must be fn (Allocator, std.Io, *const Reader) ![]Span");
    }
}

test "layout registry exposes the mbr driver" {
    try std.testing.expectEqual(types.Info.Layout.mbr, drivers[0].layout);
}
