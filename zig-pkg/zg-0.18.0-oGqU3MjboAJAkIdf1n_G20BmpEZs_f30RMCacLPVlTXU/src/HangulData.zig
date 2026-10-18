//! Hangul Data

pub const Syllable = enum {
    none,
    L,
    LV,
    LVT,
    V,
    T,
};

const syllable_mask: u4 = 0b0111;
const modern_jamo: u4 = 0b1000;

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u4 = undefined,
};

const data = @import("hangul");
const hangul = Data{
    .s1 = &data.s1,
    .s2 = &data.s2,
};

pub const SBase = data.SBase;
pub const LBase = data.LBase;
pub const VBase = data.VBase;
pub const TBase = data.TBase;
pub const LCount = data.LCount;
pub const VCount = data.VCount;
pub const TCount = data.TCount;
pub const NCount = data.NCount;
pub const SCount = data.SCount;

/// Returns the Hangul syllable type for `cp`.
pub fn syllable(cp: u21) Syllable {
    return @enumFromInt(value(cp) & syllable_mask);
}

/// Answers whether `cp` is a modern jamo used by the algorithmic Hangul
/// composition and naming algorithms.
pub fn isModernJamo(cp: u21) bool {
    return value(cp) & modern_jamo != 0;
}

fn value(cp: u21) u4 {
    return hangul.s2[hangul.s1[cp >> 8] + (cp & 0xff)];
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
