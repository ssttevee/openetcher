const std = @import("std");

const codec_api = @import("codec.zig");

const flate = std.compress.flate;

pub const State = struct {
    window: [flate.max_window_len]u8,
    decompress: flate.Decompress,
};

pub fn init(state: *State, args: codec_api.InitArgs) error{}!void {
    state.decompress = .init(args.encoded_reader, .gzip, &state.window);
}

pub fn reader(state: *State) *std.Io.Reader {
    return &state.decompress.reader;
}

pub fn deinit(state: *State) void {
    _ = state;
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .gzip;
pub const magic: []const u8 = &.{ 0x1f, 0x8b };
