//! Low-level deterministic finite automata for UTF-8-family encodings.
//!
//! Each namespace exposes the byte-class table, state-transition table,
//! codepoint mask table, and accepting and rejecting states used by its
//! decoder.

/// UTF-8 DFA primitives.
pub const utf8 = struct {
    /// Maps each byte to its transition class.
    pub const dfa: [256]u8 = .{
        // zig fmt: off
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 80..9f
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // a0..bf
        8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // c0..df
        0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3, // e0..ef
        0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, // f0..ff
    }; // zig fmt: on

    /// Maps a state plus a byte class to the next state.
    pub const state = unicode_state;

    /// Maps each byte class to its initial codepoint mask.
    pub const mask = unicode_mask;

    /// Successful codepoint parse.
    pub const accept: u8 = 0;

    /// Error state.
    pub const reject: u8 = 12;

    const decoder = DfaDecoder(dfa, state, mask, accept);

    /// Consumes one byte, updating the DFA state and codepoint in progress.
    pub inline fn decode1(dfa_state: *u8, codepoint: *u32, byte: u8) void {
        decoder.decode1(dfa_state, codepoint, byte);
    }

    /// Consumes one byte, updating the DFA state.
    pub inline fn step1(dfa_state: *u8, byte: u8) void {
        decoder.step1(dfa_state, byte);
    }
};

/// WTF-8 DFA primitives.
pub const wtf8 = struct {
    /// Maps each byte to its transition class.
    pub const dfa: [256]u8 = blk: {
        var table = utf8.dfa;
        table[0xe0] = 0x3;
        table[0xed] = 0x3;
        break :blk table;
    };

    /// Maps a state plus a byte class to the next state.
    pub const state = unicode_state;

    /// Maps each byte class to its initial codepoint mask.
    pub const mask = unicode_mask;

    /// Successful codepoint parse.
    pub const accept: u8 = 0;

    /// Error state.
    pub const reject: u8 = 12;

    const decoder = DfaDecoder(dfa, state, mask, accept);

    /// Consumes one byte, updating the DFA state and codepoint in progress.
    pub inline fn decode1(dfa_state: *u8, codepoint: *u32, byte: u8) void {
        decoder.decode1(dfa_state, codepoint, byte);
    }

    /// Consumes one byte, updating the DFA state.
    pub inline fn step1(dfa_state: *u8, byte: u8) void {
        decoder.step1(dfa_state, byte);
    }
};

/// Plan 9 UTF-8 DFA primitives.
pub const plan9 = struct {
    /// Maps each byte to its transition class.
    pub const dfa: [256]u8 = .{
        // zig fmt: off
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
        1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, // 80..9f
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, // a0..bf
        7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, // c0..df
        9, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,11,10,10,10,10,10,10,10,13,12,12,12,15,14, 7, 7, // e0..ff
    }; // zig fmt: on

    /// Maps each byte class to its initial codepoint mask.
    pub const mask: [16]u8 = .{
        0xff,
        0,
        0,
        0,
        0,
        0,
        0b0001_1111,
        0,
        0b0000_1111,
        0b0000_1111,
        0b0000_0111,
        0b0000_0111,
        0b0000_0011,
        0b0000_0011,
        0b0000_0001,
        0b0000_0001,
    };

    /// Maps a state plus a byte class to the next state.
    pub const state: [176]u8 = .{
        // zig fmt: off
        0,  16, 16, 16, 16, 16, 32, 16, 48, 112, 64, 128, 80, 144, 96, 160,
        16, 16, 16, 16, 16, 16, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 0,  0,  0,  0,  0,  16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 32, 32, 32, 32, 32, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 48, 48, 48, 48, 48, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 64, 64, 64, 64, 64, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 80, 80, 80, 80, 80, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 16, 16, 16, 16, 32, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 16, 16, 16, 48, 48, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 16, 16, 64, 64, 64, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
        16, 16, 80, 80, 80, 80, 16, 16, 16, 16,  16, 16,  16, 16,  16,  16,
    }; // zig fmt: on

    /// Successful codepoint parse.
    pub const accept: u8 = 0;

    /// Error state.
    pub const reject: u8 = 16;

    const decoder = DfaDecoder(dfa, state, mask, accept);

    /// Consumes one byte, updating the DFA state and codepoint in progress.
    pub inline fn decode1(dfa_state: *u8, codepoint: *u32, byte: u8) void {
        decoder.decode1(dfa_state, codepoint, byte);
    }

    /// Consumes one byte, updating the DFA state.
    pub inline fn step1(dfa_state: *u8, byte: u8) void {
        decoder.step1(dfa_state, byte);
    }
};

const unicode_state: [108]u8 = .{
    // zig fmt: off
    0,  12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 0,  12, 12, 12, 12, 12, 0,  12, 0,  12, 12,
    12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12,
    12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
}; // zig fmt: on

const unicode_mask: [12]u8 = .{
    0xff,
    0,
    0b0011_1111,
    0b0001_1111,
    0b0000_1111,
    0b0000_0111,
    0b0000_0011,
    0,
    0,
    0,
    0,
    0,
};

fn DfaDecoder(
    comptime byte_dfa: [256]u8,
    comptime state_dfa: anytype,
    comptime class_mask: anytype,
    comptime accept_state: u8,
) type {
    return struct {
        inline fn decode1(dfa_state: *u8, codepoint: *u32, byte: u8) void {
            const class = byte_dfa[byte];
            codepoint.* = if (dfa_state.* == accept_state)
                @as(u32, byte & class_mask[class])
            else
                (codepoint.* << 6) | (byte & 0x3f);
            dfa_state.* = state_dfa[@as(usize, dfa_state.*) + class];
        }

        inline fn step1(dfa_state: *u8, byte: u8) void {
            const class = byte_dfa[byte];
            dfa_state.* = state_dfa[@as(usize, dfa_state.*) + class];
        }
    };
}

test "encoding namespaces expose DFA primitives" {
    try std.testing.expectEqual(@as(usize, 256), utf8.dfa.len);
    try std.testing.expectEqual(@as(usize, 256), wtf8.dfa.len);
    try std.testing.expectEqual(@as(usize, 256), plan9.dfa.len);
    try std.testing.expectEqual(@as(u8, 4), utf8.dfa[0xed]);
    try std.testing.expectEqual(@as(u8, 3), wtf8.dfa[0xed]);
    try std.testing.expectEqual(@as(u8, 15), plan9.dfa[0xfc]);
    try std.testing.expectEqualSlices(u8, &utf8.state, &wtf8.state);
    try std.testing.expectEqual(@as(u8, 12), utf8.reject);
    try std.testing.expectEqual(@as(u8, 16), plan9.reject);
    for (plan9.state) |state| try std.testing.expectEqual(@as(u8, 0), state % 16);
}

test "decode1 and step1 consume one byte at a time" {
    try expectDecode1(utf8, "\xe2\x98\x83", 0x2603);
    try expectDecode1(wtf8, "\xed\xa0\x80", 0xd800);
    try expectDecode1(plan9, "\xfc\x84\x80\x80\x80\x80", 0x4000_000);

    var dfa_state = utf8.accept;
    var codepoint: u32 = 0;
    for ("\xed\xa0\x80") |byte| utf8.decode1(&dfa_state, &codepoint, byte);
    try std.testing.expectEqual(utf8.reject, dfa_state);
}

fn expectDecode1(comptime encoding: type, bytes: []const u8, expected: u32) !void {
    var decode_state = encoding.accept;
    var step_state = encoding.accept;
    var codepoint: u32 = 0;

    for (bytes) |byte| {
        encoding.decode1(&decode_state, &codepoint, byte);
        encoding.step1(&step_state, byte);
        try std.testing.expectEqual(step_state, decode_state);
    }

    try std.testing.expectEqual(encoding.accept, decode_state);
    try std.testing.expectEqual(expected, codepoint);
}

const std = @import("std");
