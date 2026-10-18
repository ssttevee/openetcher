//! An Homage to Plan 9
//!
//! This adapts the Hoehrmann byte-class/state-table decoder to the original
//! six-byte UTF-8 form.  It accepts surrogate-form three-byte sequences, but
//! it still rejects all non-shortest encodings.

const byte_class = dfa.plan9.dfa;
const class_mask = dfa.plan9.mask;
const state_dfa = dfa.plan9.state;

pub const Error = error{InvalidUtf8};

pub const ErrorStrategy = enum {
    exact,
    lossy,
    assume_valid,
};

pub const UTF_ACCEPT = dfa.plan9.accept;
pub const UTF_REJECT = dfa.plan9.reject;

const weight: [4]u8 = .{ 1, 1, 0, 1 };
const utf8_uffd = [3]u8{ 0xEF, 0xBF, 0xBD };

pub fn View(comptime strategy: ErrorStrategy) type {
    return switch (strategy) {
        .exact => ExactIterator,
        .lossy => LossyIterator,
        .assume_valid => ValidIterator,
    };
}

pub fn iterator(slice: []const u8, comptime strategy: ErrorStrategy) View(strategy) {
    return View(strategy).init(slice);
}

pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
    return switch (first_byte) {
        0x00...0x7f => 1,
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf7 => 4,
        0xf8...0xfb => 5,
        0xfc...0xfd => 6,
        else => error.Utf8InvalidStartByte,
    };
}

pub fn decode(bytes: []const u8) Error!u32 {
    var cursor: usize = 0;
    return decodeCursor(bytes, &cursor);
}

pub fn decodeCursor(bytes: []const u8, cursor: *usize) Error!u32 {
    assert(cursor.* < bytes.len);

    var byte: u16 = bytes[cursor.*];
    if (byte < 0x80) {
        cursor.* += 1;
        return byte;
    }

    var class: u8 = byte_class[byte];
    var state: u8 = state_dfa[class];
    var codepoint: u32 = byte & class_mask[class];
    if (state == UTF_REJECT) return error.InvalidUtf8;

    cursor.* += 1;
    switch (class) {
        6 => if (cursor.* + 1 > bytes.len) return error.InvalidUtf8,
        8, 9 => if (cursor.* + 2 > bytes.len) return error.InvalidUtf8,
        10, 11 => if (cursor.* + 3 > bytes.len) return error.InvalidUtf8,
        12, 13 => if (cursor.* + 4 > bytes.len) return error.InvalidUtf8,
        14, 15 => if (cursor.* + 5 > bytes.len) return error.InvalidUtf8,
        else => unreachable,
    }

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    if (state == UTF_REJECT) return error.InvalidUtf8;
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    if (state == UTF_REJECT) return error.InvalidUtf8;
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    if (state == UTF_REJECT) return error.InvalidUtf8;
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    if (state == UTF_REJECT) return error.InvalidUtf8;
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    if (state != UTF_ACCEPT) return error.InvalidUtf8;
    cursor.* += 1;
    return codepoint;
}

pub fn validate(bytes: []const u8) bool {
    var cursor: usize = 0;
    return validateCursor(bytes, &cursor);
}

pub fn validateCursor(bytes: []const u8, cursor: *usize) bool {
    var state: u8 = UTF_ACCEPT;
    var class: u8 = 0;

    while (cursor.* < bytes.len) : (cursor.* += 1) {
        assert(state == UTF_ACCEPT);
        const byte = bytes[cursor.*];
        if (byte < 0x80) continue;

        class = byte_class[byte];
        state = state_dfa[class];
        if (state == UTF_REJECT) return false;

        switch (class) {
            6 => if (cursor.* + 2 > bytes.len) return false,
            8, 9 => if (cursor.* + 3 > bytes.len) return false,
            10, 11 => if (cursor.* + 4 > bytes.len) return false,
            12, 13 => if (cursor.* + 5 > bytes.len) return false,
            14, 15 => if (cursor.* + 6 > bytes.len) return false,
            else => unreachable,
        }

        cursor.* += 1;
        state = state_dfa[state + byte_class[bytes[cursor.*]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return false;

        cursor.* += 1;
        state = state_dfa[state + byte_class[bytes[cursor.*]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return false;

        cursor.* += 1;
        state = state_dfa[state + byte_class[bytes[cursor.*]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return false;

        cursor.* += 1;
        state = state_dfa[state + byte_class[bytes[cursor.*]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return false;

        cursor.* += 1;
        state = state_dfa[state + byte_class[bytes[cursor.*]]];
        if (state == UTF_REJECT) return false;
    }

    return true;
}

pub fn countCodepoints(bytes: []const u8) Error!usize {
    var state: u8 = UTF_ACCEPT;
    var i: usize = 0;
    var class: u8 = 0;
    var count: usize = 0;

    while (i < bytes.len) : (i += 1) {
        assert(state == UTF_ACCEPT);
        count += 1;

        const byte = bytes[i];
        if (byte < 0x80) continue;

        class = byte_class[byte];
        state = state_dfa[class];
        if (state == UTF_REJECT) return error.InvalidUtf8;

        switch (class) {
            6 => if (i + 2 > bytes.len) return error.InvalidUtf8,
            8, 9 => if (i + 3 > bytes.len) return error.InvalidUtf8,
            10, 11 => if (i + 4 > bytes.len) return error.InvalidUtf8,
            12, 13 => if (i + 5 > bytes.len) return error.InvalidUtf8,
            14, 15 => if (i + 6 > bytes.len) return error.InvalidUtf8,
            else => unreachable,
        }

        i += 1;
        state = state_dfa[state + byte_class[bytes[i]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return error.InvalidUtf8;

        i += 1;
        state = state_dfa[state + byte_class[bytes[i]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return error.InvalidUtf8;

        i += 1;
        state = state_dfa[state + byte_class[bytes[i]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return error.InvalidUtf8;

        i += 1;
        state = state_dfa[state + byte_class[bytes[i]]];
        if (state == UTF_ACCEPT) continue;
        if (state == UTF_REJECT) return error.InvalidUtf8;

        i += 1;
        state = state_dfa[state + byte_class[bytes[i]]];
        if (state == UTF_REJECT) return error.InvalidUtf8;
    }

    return count;
}

pub const lossy = struct {
    pub fn iterator(slice: []const u8) LossyIterator {
        return .init(slice);
    }

    pub fn decode(bytes: []const u8) u32 {
        var cursor: usize = 0;
        return lossy.decodeCursor(bytes, &cursor);
    }

    pub fn decodeCursor(bytes: []const u8, cursor: *usize) u32 {
        assert(cursor.* < bytes.len);

        const start = cursor.*;
        cursor.* += 1;

        var byte = bytes[start];
        if (byte < 0x80) return byte;

        var class = byte_class[byte];
        var state = state_dfa[class];
        if (state == UTF_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            return 0xfffd;
        }

        var codepoint: u32 = byte & class_mask[class];
        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;
        if (state == UTF_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            cursor.* -= 1;
            return 0xfffd;
        }

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;
        if (state == UTF_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            cursor.* -= rollbackFromThirdByte(byte);
            return 0xfffd;
        }

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;
        if (state == UTF_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            cursor.* -= rollbackFromFourthByte(byte);
            return 0xfffd;
        }

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;
        if (state == UTF_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            cursor.* -= rollbackFromFifthByte(byte);
            return 0xfffd;
        }

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_REJECT) {
            @branchHint(.cold);
            cursor.* -= rollbackFromSixthByte(byte);
            return 0xfffd;
        }

        assert(state == UTF_ACCEPT);
        return codepoint;
    }

    pub fn validate(bytes: []const u8) bool {
        return validateExact(bytes);
    }

    pub fn countCodepoints(bytes: []const u8) usize {
        var cursor: usize = 0;
        var count: usize = 0;
        while (cursor < bytes.len) {
            _ = lossy.decodeCursor(bytes, &cursor);
            count += 1;
        }
        return count;
    }
};

pub const valid = struct {
    pub fn iterator(slice: []const u8) ValidIterator {
        return .init(slice);
    }

    pub fn decode(bytes: []const u8) u32 {
        var cursor: usize = 0;
        return valid.decodeCursor(bytes, &cursor);
    }

    pub fn decodeCursor(bytes: []const u8, cursor: *usize) u32 {
        var byte: u16 = bytes[cursor.*];
        cursor.* += 1;
        if (byte < 0x80) return byte;

        var class: u8 = byte_class[byte];
        var state: u8 = state_dfa[class];
        var codepoint: u32 = byte & class_mask[class];

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;

        byte = bytes[cursor.*];
        class = byte_class[byte];
        state = state_dfa[state + class];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        if (state == UTF_ACCEPT) return codepoint;

        byte = bytes[cursor.*];
        codepoint = (byte & 0x3f) | (codepoint << 6);
        cursor.* += 1;
        return codepoint;
    }

    pub fn validate(bytes: []const u8) bool {
        return validateExact(bytes);
    }

    pub fn countCodepoints(bytes: []const u8) usize {
        var count: usize = 0;
        for (bytes) |byte| {
            count += weight[byte >> 6];
        }
        return count;
    }
};

const ExactIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn init(bytes: []const u8) ExactIterator {
        return .{ .bytes = bytes };
    }

    pub fn nextCodepoint(iter: *ExactIterator) Error!?u32 {
        if (iter.i >= iter.bytes.len) return null;
        return try decodeCursor(iter.bytes, &iter.i);
    }

    pub fn nextCodepointSlice(iter: *ExactIterator) Error!?[]const u8 {
        if (iter.i >= iter.bytes.len) return null;
        const start = iter.i;
        _ = try decodeCursor(iter.bytes, &iter.i);
        return iter.bytes[start..iter.i];
    }

    pub fn peek(iter: *ExactIterator, n: usize) Error![]const u8 {
        var remaining = n;
        var i = iter.i;
        while (remaining > 0 and i < iter.bytes.len) : (remaining -= 1) {
            _ = try decodeCursor(iter.bytes, &i);
        }
        return iter.bytes[iter.i..i];
    }
};

const LossyIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn init(bytes: []const u8) LossyIterator {
        return .{ .bytes = bytes };
    }

    pub fn nextCodepoint(iter: *LossyIterator) ?u32 {
        if (iter.i >= iter.bytes.len) return null;
        return lossy.decodeCursor(iter.bytes, &iter.i);
    }

    pub fn nextCodepointSlice(iter: *LossyIterator) ?[]const u8 {
        if (iter.i >= iter.bytes.len) return null;
        const start = iter.i;
        if (lossy.decodeCursor(iter.bytes, &iter.i) == 0xfffd) return &utf8_uffd;
        return iter.bytes[start..iter.i];
    }

    pub fn peek(iter: *LossyIterator) []const u8 {
        const i = iter.i;
        defer iter.i = i;
        return iter.nextCodepointSlice() orelse "";
    }
};

const ValidIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn init(bytes: []const u8) ValidIterator {
        return .{ .bytes = bytes };
    }

    pub fn nextCodepoint(iter: *ValidIterator) ?u32 {
        if (iter.i >= iter.bytes.len) return null;
        return valid.decodeCursor(iter.bytes, &iter.i);
    }

    pub fn nextCodepointSlice(iter: *ValidIterator) ?[]const u8 {
        if (iter.i >= iter.bytes.len) return null;
        const start = iter.i;
        iter.i += cpLengthAssumeValid(iter.bytes[iter.i]);
        return iter.bytes[start..iter.i];
    }

    pub fn peek(iter: *ValidIterator, n: usize) []const u8 {
        var remaining = n;
        var i = iter.i;
        while (remaining > 0 and i < iter.bytes.len) : (remaining -= 1) {
            i += cpLengthAssumeValid(iter.bytes[i]);
        }
        return iter.bytes[iter.i..i];
    }
};

fn cpLengthAssumeValid(byte: u8) usize {
    return switch (byte) {
        0x00...0x7f => 1,
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf7 => 4,
        0xf8...0xfb => 5,
        0xfc...0xfd => 6,
        else => unreachable,
    };
}

fn validateExact(bytes: []const u8) bool {
    return validate(bytes);
}

inline fn rollbackFromThirdByte(byte: u8) usize {
    if (state_dfa[byte_class[byte]] == UTF_REJECT) return 2;
    return 1;
}

inline fn rollbackFromFourthByte(byte: u8) usize {
    if (state_dfa[byte_class[byte]] == UTF_REJECT) return 3;
    return 1;
}

inline fn rollbackFromFifthByte(byte: u8) usize {
    if (state_dfa[byte_class[byte]] == UTF_REJECT) return 4;
    return 1;
}

inline fn rollbackFromSixthByte(byte: u8) usize {
    if (state_dfa[byte_class[byte]] == UTF_REJECT) return 5;
    return 1;
}

test "decode handles ascii through six-byte and surrogate-form codepoints" {
    try testing.expectEqual(@as(u32, 'A'), try decode("A"));
    try testing.expectEqual(@as(u32, 0x7ff), try decode(&.{ 0xdf, 0xbf }));
    try testing.expectEqual(@as(u32, 0xd800), try decode(&.{ 0xed, 0xa0, 0x80 }));
    try testing.expectEqual(@as(u32, 0x1_0000), try decode(&.{ 0xf0, 0x90, 0x80, 0x80 }));
    try testing.expectEqual(@as(u32, 0x20_0000), try decode(&.{ 0xf8, 0x88, 0x80, 0x80, 0x80 }));
    try testing.expectEqual(@as(u32, 0x4000_000), try decode(&.{ 0xfc, 0x84, 0x80, 0x80, 0x80, 0x80 }));
}

test "decodeCursor advances through mixed-width input" {
    const bytes = [_]u8{
        'A',
        0xdf,
        0xbf,
        0xed,
        0xa0,
        0x80,
        0xf0,
        0x90,
        0x80,
        0x80,
        0xf8,
        0x88,
        0x80,
        0x80,
        0x80,
        0xfc,
        0x84,
        0x80,
        0x80,
        0x80,
        0x80,
    };

    var cursor: usize = 0;
    try testing.expectEqual(@as(u32, 'A'), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(u32, 0x7ff), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(u32, 0xd800), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(u32, 0x1_0000), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(u32, 0x20_0000), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(u32, 0x4000_000), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(bytes.len, cursor);
}

test "four-byte decoding does not stop at the modern Unicode limit" {
    try testing.expectEqual(@as(u32, 0x10ffff), try decode(&.{ 0xf4, 0x8f, 0xbf, 0xbf }));
    try testing.expectEqual(@as(u32, 0x110000), try decode(&.{ 0xf4, 0x90, 0x80, 0x80 }));
    try testing.expectEqual(@as(u32, 0x1fffff), try decode(&.{ 0xf7, 0xbf, 0xbf, 0xbf }));
}

test "five-byte decoding begins at 0x200000" {
    try testing.expectError(error.InvalidUtf8, decode(&.{ 0xf8, 0x87, 0xbf, 0xbf, 0xbf }));
    try testing.expectEqual(@as(u32, 0x200000), try decode(&.{ 0xf8, 0x88, 0x80, 0x80, 0x80 }));
}

test "validate and countCodepoints accept valid input" {
    const bytes = [_]u8{
        'A',
        0xdf,
        0xbf,
        0xed,
        0xa0,
        0x80,
        0xf0,
        0x90,
        0x80,
        0x80,
        0xf8,
        0x88,
        0x80,
        0x80,
        0x80,
        0xfc,
        0x84,
        0x80,
        0x80,
        0x80,
        0x80,
    };

    var cursor: usize = 0;
    try testing.expect(validateCursor(&bytes, &cursor));
    try testing.expectEqual(bytes.len, cursor);
    try testing.expect(validate(&bytes));
    try testing.expectEqual(@as(usize, 6), try countCodepoints(&bytes));
    try testing.expectEqual(@as(usize, 6), valid.countCodepoints(&bytes));
}

test "invalid data reports the first bad byte" {
    const bytes = [_]u8{ 'A', 0xc0, 0x80, 'B' };

    var cursor: usize = 0;
    try testing.expectEqual(@as(u32, 'A'), try decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
    try testing.expectError(error.InvalidUtf8, decodeCursor(&bytes, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);

    cursor = 0;
    try testing.expect(!validateCursor(&bytes, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
    try testing.expectError(error.InvalidUtf8, countCodepoints(&bytes));
}

test "truncated sequences are rejected" {
    try testing.expectError(error.InvalidUtf8, decode(&.{ 0xe0, 0xa0 }));
    try testing.expectError(error.InvalidUtf8, decode(&.{ 0xf8, 0x88, 0x80, 0x80 }));
    try testing.expect(!validate(&.{ 0xe0, 0xa0 }));
    try testing.expect(!validate(&.{ 0xf8, 0x88, 0x80, 0x80 }));
}

test "non-shortest forms are rejected in every multibyte width" {
    try expectRejectNonShortest(&.{ 0xc0, 0x80 }, 0);
    try expectRejectNonShortest(&.{ 0xe0, 0x9f, 0xbf }, 1);
    try expectRejectNonShortest(&.{ 0xf0, 0x8f, 0xbf, 0xbf }, 1);
    try expectRejectNonShortest(&.{ 0xf8, 0x87, 0xbf, 0xbf, 0xbf }, 1);
    try expectRejectNonShortest(&.{ 0xfc, 0x83, 0xbf, 0xbf, 0xbf, 0xbf }, 1);
}

test "lossy decode replaces malformed input and follows maximal subparts" {
    const overlong = [_]u8{ 0xc0, 0x80, 'A' };
    var cursor: usize = 0;
    try testing.expectEqual(@as(u32, 0xfffd), lossy.decodeCursor(&overlong, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
    try testing.expectEqual(@as(u32, 0xfffd), lossy.decodeCursor(&overlong, &cursor));
    try testing.expectEqual(@as(usize, 2), cursor);
    try testing.expectEqual(@as(u32, 'A'), lossy.decodeCursor(&overlong, &cursor));

    const malformed = [_]u8{ 0xe0, 0xa0, 'A' };
    cursor = 0;
    try testing.expectEqual(@as(u32, 0xfffd), lossy.decodeCursor(&malformed, &cursor));
    try testing.expectEqual(@as(usize, 2), cursor);
    try testing.expectEqual(@as(u32, 'A'), lossy.decodeCursor(&malformed, &cursor));

    const truncated = [_]u8{ 0xe0, 0xa0 };
    cursor = 0;
    try testing.expectEqual(@as(u32, 0xfffd), lossy.decodeCursor(&truncated, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
    try testing.expectEqual(@as(u32, 0xfffd), lossy.decodeCursor(&truncated, &cursor));
    try testing.expectEqual(@as(usize, 2), cursor);
}

test "exact iterator matches decodeCursor" {
    const bytes = [_]u8{
        'A',
        0xdf,
        0xbf,
        0xed,
        0xa0,
        0x80,
        0xf0,
        0x90,
        0x80,
        0x80,
    };

    var iter = iterator(&bytes, .exact);
    var cursor: usize = 0;
    while (try iter.nextCodepoint()) |codepoint| {
        try testing.expectEqual(codepoint, try decodeCursor(&bytes, &cursor));
    }
    try testing.expectEqual(bytes.len, cursor);

    iter = iterator(&bytes, .exact);
    try testing.expectEqualStrings(bytes[0..6], try iter.peek(3));
}

test "lossy iterator slices use replacement bytes for malformed input" {
    const bytes = [_]u8{ 0xe0, 0xa0, 'A' };
    var iter = lossy.iterator(&bytes);
    try testing.expectEqualStrings(&utf8_uffd, iter.nextCodepointSlice().?);
    try testing.expectEqualStrings("A", iter.nextCodepointSlice().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.nextCodepointSlice());
}

test "valid iterator slices match the original bytes" {
    const bytes = [_]u8{
        'A',
        0xdf,
        0xbf,
        0xed,
        0xa0,
        0x80,
        0xf8,
        0x88,
        0x80,
        0x80,
        0x80,
    };

    var iter = valid.iterator(&bytes);
    try testing.expectEqualStrings("A", iter.nextCodepointSlice().?);
    try testing.expectEqualStrings(bytes[1..3], iter.nextCodepointSlice().?);
    try testing.expectEqualStrings(bytes[3..6], iter.nextCodepointSlice().?);
    try testing.expectEqualStrings(bytes[6..11], iter.nextCodepointSlice().?);

    iter = valid.iterator(&bytes);
    try testing.expectEqualStrings(bytes[0..6], iter.peek(3));
}

fn expectRejectNonShortest(bytes: []const u8, reject_at: usize) !void {
    var cursor: usize = 0;
    try testing.expectError(error.InvalidUtf8, decode(bytes));
    try testing.expectError(error.InvalidUtf8, decodeCursor(bytes, &cursor));
    try testing.expectEqual(reject_at, cursor);

    cursor = 0;
    try testing.expect(!validateCursor(bytes, &cursor));
    try testing.expectEqual(reject_at, cursor);

    try testing.expect(!validate(bytes));
    try testing.expectError(error.InvalidUtf8, countCodepoints(bytes));
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const dfa = @import("dfa.zig");
