const std = @import("std");

const contract = @import("../../contract.zig");

/// Compressed-container identifiers, ordered by nothing; the registry below
/// defines detection precedence.
pub const Compression = enum {
    none,
    gzip,
    xz,
    zstd,
    bzip2,
};

/// What one codec's `init` receives. Streaming codecs use `encoded_reader`;
/// process-based decoders (bzip2 today) use `io` and `path` instead. Callers
/// enforce the decoded size limit while reading, so codecs need not.
pub const InitArgs = struct {
    allocator: std.mem.Allocator,
    /// Streaming view of the encoded bytes; valid for the decoder's lifetime.
    encoded_reader: *std.Io.Reader,
    io: std.Io,
    path: []const u8,
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
///   `pub const State: type` - decoder state, initialized in place; it
///       lives inside the stream and never moves, so it may point into
///       itself
///   `pub fn init(*State, InitArgs) !void`
///   `pub fn reader(*State) *std.Io.Reader` - the decoded bytes
///   `pub fn deinit(*State) void` - releases what `init` acquired
pub const codecs = .{
    @import("gzip.zig"),
    @import("xz.zig"),
    @import("zstd.zig"),
    @import("bzip2.zig"),
};

/// One decoder of any registered codec, generated from `codecs` with one
/// field per codec named after its `id`, so dispatch is a `switch` rather
/// than a function pointer and the state needs no allocation of its own.
pub const Decoder = Decoder: {
    var names: [codecs.len][]const u8 = undefined;
    var types: [codecs.len]type = undefined;
    for (codecs, &names, &types) |C, *name, *T| {
        name.* = @tagName(C.id);
        T.* = C.State;
    }
    // Tags follow registry order, so a tag's value indexes `codecs`.
    const Tag = @Enum(u8, .exhaustive, &names, &std.simd.iota(u8, codecs.len));
    break :Decoder @Union(.auto, Tag, &names, &types, &@splat(.{}));
};

comptime {
    var seen: std.EnumSet(Compression) = .initOne(.none);
    for (codecs, 0..) |C, index| {
        contract.expectDecls(C, "codec", &.{ "id", "magic", "State", "init", "reader", "deinit" });
        contract.expectFn(C, "init", &.{ *C.State, InitArgs }, void);
        contract.expectFn(C, "reader", &.{*C.State}, *std.Io.Reader);
        contract.expectFn(C, "deinit", &.{*C.State}, void);
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

/// Initializes `decoder` in place as the codec registered for `compression`.
pub fn initDecoder(decoder: *Decoder, compression: Compression, args: InitArgs) !void {
    inline for (codecs) |C| {
        if (C.id == compression) {
            decoder.* = @unionInit(Decoder, @tagName(C.id), undefined);
            return C.init(&@field(decoder, @tagName(C.id)), args);
        }
    }
    return error.UnsupportedCompression;
}

pub fn decodedReader(decoder: *Decoder) *std.Io.Reader {
    return switch (decoder.*) {
        inline else => |*state, tag| codecs[@backingInt(tag)].reader(state),
    };
}

pub fn deinitDecoder(decoder: *Decoder) void {
    switch (decoder.*) {
        inline else => |*state, tag| codecs[@backingInt(tag)].deinit(state),
    }
    decoder.* = undefined;
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
