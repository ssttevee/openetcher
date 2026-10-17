const std = @import("std");

const contract = @import("../../contract.zig");
const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

const Reader = reader_mod.Reader;
const expectFn = contract.expectFn;
const Probe = types.Info.Probe;

/// Filesystem drivers, in content-sniffing precedence.
///
/// Add a filesystem: create one module satisfying the contract below, then
/// list it here. `validate` checks every entry at compile time, and callers
/// dispatch with `inline for`, so each call is static.
///
/// Required declarations:
///   `pub const name: []const u8` - label used in partition failure reasons
///   `pub const unrecognized: Filesystem` - tag reported when probing fails
///   `pub fn detect(std.Io, *const Reader) bool` - cheap, allocation-free sniff
///   `pub fn probeRegion(Allocator, std.Io, *const Reader) !Probe`
///   `pub fn collectRanges(Allocator, std.Io, *const Reader) ![]ByteRange`
///
/// Optional declarations:
///   `pub const mbr_types: [_]u8` - MBR types routed here before sniffing
///   `pub const raw_layout: Layout` - set when the driver can plan a whole
///       unpartitioned image; then `pub const filesystem: Filesystem` and
///       `pub fn blockSize(std.Io, *const Reader) !u32` are required too
///
/// Offsets in and out of every function are relative to the reader, whose
/// offset 0 is the start of the candidate region.
pub const drivers = .{
    @import("iso9660.zig"),
    @import("fat.zig"),
    @import("squashfs.zig"),
    @import("ext4.zig"),
};

/// Every error a driver's `probeRegion` or `collectRanges` can return.
pub const Error = Error: {
    var set = error{};
    for (drivers) |D| {
        set = set || contract.ErrorSetOf(D.probeRegion) || contract.ErrorSetOf(D.collectRanges);
    }
    break :Error set;
};

comptime {
    for (drivers) |D| validate(D);
    checkMbrTypesAreUnique();
}

/// True when `D` claims MBR partition type `partition_type`.
pub fn claimsMbrType(comptime D: type, partition_type: u8) bool {
    if (!@hasDecl(D, "mbr_types")) return false;
    return std.mem.indexOfScalar(u8, &D.mbr_types, partition_type) != null;
}

/// Checks `D` against the driver contract. Generic callers invoke it first
/// so a broken driver reports the contract, not a downstream type error.
pub fn validate(comptime D: type) void {
    contract.expectDecls(D, "filesystem driver", &.{ "name", "unrecognized", "detect", "probeRegion", "collectRanges" });
    _ = @as([]const u8, D.name);
    _ = @as(types.Info.Filesystem, D.unrecognized);
    expectFn(D, "detect", &.{ std.Io, *const Reader }, bool);
    expectFn(D, "probeRegion", &.{ std.mem.Allocator, std.Io, *const Reader }, Probe);
    expectFn(D, "collectRanges", &.{ std.mem.Allocator, std.Io, *const Reader }, []range.ByteRange);
    if (@hasDecl(D, "mbr_types")) _ = @as([]const u8, &D.mbr_types);
    if (@hasDecl(D, "raw_layout")) {
        _ = @as(types.Info.Layout, D.raw_layout);
        _ = @as(types.Info.Filesystem, D.filesystem);
        expectFn(D, "blockSize", &.{ std.Io, *const Reader }, u32);
    }
}

fn checkMbrTypesAreUnique() void {
    var owner: [256]?[]const u8 = @splat(null);
    for (drivers) |D| {
        if (!@hasDecl(D, "mbr_types")) continue;
        for (D.mbr_types) |partition_type| {
            if (owner[partition_type]) |other| {
                @compileError(std.fmt.comptimePrint("MBR type 0x{x:0>2} is claimed by both {s} and {s}", .{ partition_type, other, D.name }));
            }
            owner[partition_type] = D.name;
        }
    }
}

test "claimsMbrType routes FAT partition types" {
    const fat = @import("fat.zig");
    const ext4 = @import("ext4.zig");
    try std.testing.expect(claimsMbrType(fat, 0x06));
    try std.testing.expect(claimsMbrType(fat, 0x0c));
    try std.testing.expect(!claimsMbrType(fat, 0x83));
    try std.testing.expect(!claimsMbrType(ext4, 0x83));
}
