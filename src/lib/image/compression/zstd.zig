const std = @import("std");

const codec_api = @import("codec.zig");

const zstd = std.compress.zstd;

pub const State = struct {
    allocator: std.mem.Allocator,
    /// Allocated rather than inline: at over 8 MiB it would size every
    /// variant of `codec.Decoder`, whichever codec is in use.
    window: []u8,
    decompress: zstd.Decompress,
};

pub fn init(state: *State, args: codec_api.InitArgs) error{OutOfMemory}!void {
    const window = try args.allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
    state.* = .{
        .allocator = args.allocator,
        .window = window,
        .decompress = .init(args.encoded_reader, window, .{}),
    };
}

pub fn reader(state: *State) *std.Io.Reader {
    return &state.decompress.reader;
}

pub fn deinit(state: *State) void {
    state.allocator.free(state.window);
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .zstd;
pub const magic: []const u8 = &.{ 0x28, 0xb5, 0x2f, 0xfd };
