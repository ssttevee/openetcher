const std = @import("std");

const range = @import("../../range.zig");
const reader_mod = @import("../reader.zig");
const types = @import("../types.zig");

const Reader = reader_mod.Reader;
const PartitionInfo = types.Info.PartitionInfo;

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
///   `pub fn probeRegion(Allocator, std.Io, *const Reader) !PartitionInfo`
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
    for ([_][]const u8{ "name", "unrecognized", "detect", "probeRegion", "collectRanges" }) |decl| {
        if (!@hasDecl(D, decl)) @compileError(@typeName(D) ++ ": filesystem driver is missing `pub " ++ decl ++ "`");
    }
    _ = @as([]const u8, D.name);
    _ = @as(types.Info.Filesystem, D.unrecognized);
    expectFn(D, "detect", &.{ std.Io, *const Reader }, bool);
    expectFn(D, "probeRegion", &.{ std.mem.Allocator, std.Io, *const Reader }, PartitionInfo);
    expectFn(D, "collectRanges", &.{ std.mem.Allocator, std.Io, *const Reader }, []range.ByteRange);
    if (@hasDecl(D, "mbr_types")) _ = @as([]const u8, &D.mbr_types);
    if (@hasDecl(D, "raw_layout")) {
        _ = @as(types.Info.Layout, D.raw_layout);
        _ = @as(types.Info.Filesystem, D.filesystem);
        expectFn(D, "blockSize", &.{ std.Io, *const Reader }, u32);
    }
}

/// Requires `D.decl` to take exactly `params` and return `payload`, either
/// directly or inside an error union.
fn expectFn(comptime D: type, comptime decl: []const u8, comptime params: []const type, comptime payload: type) void {
    const where = @typeName(D) ++ "." ++ decl;
    if (!@hasDecl(D, decl)) @compileError(where ++ " is required");
    const info = switch (@typeInfo(@TypeOf(@field(D, decl)))) {
        .@"fn" => |info| info,
        else => @compileError(where ++ " must be a function"),
    };
    if (info.param_types.len != params.len) @compileError(where ++ " has the wrong number of parameters");
    for (info.param_types, params) |param, expected| {
        if (param != expected) @compileError(where ++ " expects a parameter of type " ++ @typeName(expected));
    }
    const returned = info.return_type.?;
    const actual = switch (@typeInfo(returned)) {
        .error_union => |error_union| error_union.payload,
        else => returned,
    };
    if (actual != payload) @compileError(where ++ " must return " ++ @typeName(payload));
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
