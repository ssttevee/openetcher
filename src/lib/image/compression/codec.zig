const std = @import("std");

/// Compressed-container identifiers, ordered by nothing; the registry below
/// defines detection precedence.
pub const Compression = enum {
    none,
    gzip,
    xz,
    zstd,
    bzip2,
};

/// What one codec's `open` receives. Streaming codecs use `encoded_reader`;
/// process-based fallbacks (bzip2 today) additionally use `io`, `path`, and
/// `max_image_size`.
pub const OpenArgs = struct {
    allocator: std.mem.Allocator,
    /// Streaming view of the encoded bytes; valid for the decoder's lifetime.
    encoded_reader: *std.Io.Reader,
    io: std.Io,
    path: []const u8,
    max_image_size: ?u64,
};

/// What one codec's `open` returns. The codec owns every allocation behind
/// `context`; the caller runs `deinit_fn` before tearing down the encoded
/// reader.
pub const Opened = struct {
    reader: *std.Io.Reader,
    translate_errors: bool = false,
    context: ?*anyopaque = null,
    deinit_fn: ?*const fn (allocator: std.mem.Allocator, context: *anyopaque) void = null,
};

pub const Codec = struct {
    id: Compression,
    /// Magic-byte prefix identifying this container.
    magic: []const u8,
    open: *const fn (args: OpenArgs) anyerror!Opened,
};

pub fn detect(magic: []const u8) Compression {
    for (&codecs) |*codec| {
        if (hasMagicPrefix(magic, codec.magic)) return codec.id;
    }
    return .none;
}

pub fn hasMagicPrefix(bytes: []const u8, magic: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes.len < magic.len) return std.mem.eql(u8, bytes, magic[0..bytes.len]);
    return std.mem.eql(u8, bytes[0..magic.len], magic);
}

/// Detection precedence: gzip, xz, zstd, bzip2.
pub const codecs = [_]Codec{
    @import("gzip.zig").codec,
    @import("xz.zig").codec,
    @import("zstd.zig").codec,
    @import("bzip2.zig").codec,
};

test "detect maps magic prefixes through the registry" {
    try std.testing.expectEqual(Compression.gzip, detect(&.{ 0x1f, 0x8b, 0x08 }));
    try std.testing.expectEqual(Compression.xz, detect(&.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 }));
    try std.testing.expectEqual(Compression.zstd, detect(&.{ 0x28, 0xb5, 0x2f, 0xfd }));
    try std.testing.expectEqual(Compression.bzip2, detect("BZh9"));
    try std.testing.expectEqual(Compression.none, detect("image.img.gz"));
}
