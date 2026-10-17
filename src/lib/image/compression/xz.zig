const std = @import("std");

const codec_api = @import("codec.zig");

const Decompress = std.compress.xz.Decompress;

/// XZ sizes its dictionary per block, so the decoder allocates it itself.
pub const State = struct {
    decompress: Decompress,
};

pub fn init(state: *State, args: codec_api.InitArgs) error{InvalidCompressedImage}!void {
    // `init` reads the stream header, so a bad header fails here.
    state.decompress = Decompress.init(args.encoded_reader, args.allocator, &.{}) catch return error.InvalidCompressedImage;
}

pub fn reader(state: *State) *std.Io.Reader {
    return &state.decompress.reader;
}

pub fn deinit(state: *State) void {
    state.decompress.deinit();
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .xz;
pub const magic: []const u8 = &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 };
