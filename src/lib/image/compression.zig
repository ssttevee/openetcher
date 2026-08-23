//! Compression codec registry facade.
//!
//! Add a codec: create compression/<name>.zig exposing `pub const codec`,
//! then list it in compression/codec.zig.

const std = @import("std");

pub const codec = @import("compression/codec.zig");
pub const Compression = codec.Compression;
pub const Codec = codec.Codec;
pub const codecs = &codec.codecs;

pub const detect = codec.detect;
/// Legacy alias.
pub const detectCompression = codec.detect;

comptime {
    _ = &codec;
}
