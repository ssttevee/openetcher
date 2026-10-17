//! Compression codec registry facade.
//!
//! Add a codec: create compression/<name>.zig satisfying the contract in
//! compression/codec.zig, then list it there.

const std = @import("std");

pub const codec = @import("compression/codec.zig");
pub const Compression = codec.Compression;
pub const codecs = codec.codecs;

pub const detect = codec.detect;
/// Legacy alias.
pub const detectCompression = codec.detect;

comptime {
    _ = &codec;
}
