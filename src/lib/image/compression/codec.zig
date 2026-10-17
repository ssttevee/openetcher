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

/// Codecs, in detection precedence.
///
/// Add a codec: create one module satisfying the contract below, then list
/// it here and add its tag to `Compression`. The checks below run at compile
/// time, so a codec cannot be left unregistered or shadow another's magic.
///
/// Required declarations:
///   `pub const id: Compression`
///   `pub const magic: []const u8` - prefix identifying the container
///   `pub fn open(OpenArgs) !Opened`
pub const codecs = .{
    @import("gzip.zig"),
    @import("xz.zig"),
    @import("zstd.zig"),
    @import("bzip2.zig"),
};

comptime {
    var seen: std.EnumSet(Compression) = .initOne(.none);
    for (codecs, 0..) |C, index| {
        for ([_][]const u8{ "id", "magic", "open" }) |decl| {
            if (!@hasDecl(C, decl)) @compileError(@typeName(C) ++ ": codec is missing `pub " ++ decl ++ "`");
        }
        if (seen.contains(C.id)) @compileError("compression ." ++ @tagName(C.id) ++ " is registered twice or is reserved");
        seen.insert(C.id);
        if (C.magic.len == 0) @compileError(@typeName(C) ++ ": magic must not be empty");

        // Detection matches prefixes, so overlapping magic would make the
        // registry order silently decide the codec.
        var other_index = 0;
        while (other_index < index) : (other_index += 1) {
            const other = codecs[other_index];
            const shorter = @min(C.magic.len, other.magic.len);
            if (std.mem.eql(u8, C.magic[0..shorter], other.magic[0..shorter])) {
                @compileError("magic bytes of ." ++ @tagName(C.id) ++ " and ." ++ @tagName(other.id) ++ " overlap");
            }
        }
    }
    for (std.enums.values(Compression)) |tag| {
        if (!seen.contains(tag)) @compileError("compression ." ++ @tagName(tag) ++ " has no registered codec");
    }
}

pub fn detect(magic: []const u8) Compression {
    inline for (codecs) |C| {
        if (hasMagicPrefix(magic, C.magic)) return C.id;
    }
    return .none;
}

/// Opens the decoder registered for `compression`.
pub fn open(compression: Compression, args: OpenArgs) !Opened {
    inline for (codecs) |C| {
        if (C.id == compression) return C.open(args);
    }
    return error.UnsupportedCompression;
}

pub fn hasMagicPrefix(bytes: []const u8, magic: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes.len < magic.len) return std.mem.eql(u8, bytes, magic[0..bytes.len]);
    return std.mem.eql(u8, bytes[0..magic.len], magic);
}

test "detect maps magic prefixes through the registry" {
    try std.testing.expectEqual(Compression.gzip, detect(&.{ 0x1f, 0x8b, 0x08 }));
    try std.testing.expectEqual(Compression.xz, detect(&.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 }));
    try std.testing.expectEqual(Compression.zstd, detect(&.{ 0x28, 0xb5, 0x2f, 0xfd }));
    try std.testing.expectEqual(Compression.bzip2, detect("BZh9"));
    try std.testing.expectEqual(Compression.none, detect("image.img.gz"));
}
