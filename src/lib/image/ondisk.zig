//! Decoding for little-endian on-disk structures.
//!
//! Each format declares its structures as `extern struct`s that mirror the
//! specification byte for byte, then pins them with `expectLayout` against
//! the offsets the specification gives, so a misdeclared field fails the
//! build rather than misparsing images. Decoding is one copy plus, on
//! big-endian hosts, a byte swap of every field.

const std = @import("std");
const builtin = @import("builtin");

const Reader = @import("reader.zig").Reader;

/// Decodes `bytes` as the little-endian structure `T`.
pub fn decode(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    comptime requireExtern(T);
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    if (builtin.cpu.arch.endian() == .big) std.mem.byteSwapAllFields(T, &value);
    return value;
}

/// Reads and decodes one `T` at `offset`.
pub fn read(comptime T: type, io: std.Io, r: *const Reader, offset: u64) Reader.ReadExactError!T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    try r.readExactlyAt(io, &bytes, offset);
    return decode(T, &bytes);
}

/// Fails the build unless `T` is `size` bytes and each field named in
/// `offsets` sits at the given byte offset. Pass offsets straight from the
/// format specification, for example `.{ .magic = 0x38 }`.
pub fn expectLayout(comptime T: type, comptime size: usize, comptime offsets: anytype) void {
    comptime {
        requireExtern(T);
        if (@sizeOf(T) != size) {
            @compileError(std.fmt.comptimePrint("{s} is {d} bytes; the format specifies {d}", .{ @typeName(T), @sizeOf(T), size }));
        }
        const info = @typeInfo(@TypeOf(offsets)).@"struct";
        for (info.field_names) |name| {
            const expected = @field(offsets, name);
            const actual = @offsetOf(T, name);
            if (actual != expected) {
                @compileError(std.fmt.comptimePrint("{s}.{s} is at offset 0x{x}; the format specifies 0x{x}", .{ @typeName(T), name, actual, expected }));
            }
        }
    }
}

fn requireExtern(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.layout == .@"extern") return,
        else => {},
    }
    @compileError(@typeName(T) ++ " must be an extern struct to have a defined on-disk layout");
}

test "decode reads little-endian fields" {
    const Header = extern struct {
        magic: u32,
        version: u16,
        flags: u16,
    };
    expectLayout(Header, 8, .{ .magic = 0, .version = 4, .flags = 6 });

    const header = decode(Header, &.{ 0x78, 0x56, 0x34, 0x12, 0x02, 0x00, 0x01, 0x80 });
    try std.testing.expectEqual(@as(u32, 0x12345678), header.magic);
    try std.testing.expectEqual(@as(u16, 2), header.version);
    try std.testing.expectEqual(@as(u16, 0x8001), header.flags);
}
