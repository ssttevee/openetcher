//! Word- and vector-at-a-time scans over large byte buffers.

const std = @import("std");

const lanes = std.simd.suggestVectorLength(u8) orelse 16;
const Lanes = @Vector(lanes, u8);
/// Vectors folded together between early-exit checks.
const unroll = 8;

/// True when every byte of `bytes` is zero.
///
/// ORs several vectors together before each branch, so the common all-zero
/// case runs at memory bandwidth instead of one compare per byte.
pub fn isZero(bytes: []const u8) bool {
    const block = lanes * unroll;
    var index: usize = 0;
    while (index + block <= bytes.len) : (index += block) {
        var folded: Lanes = @splat(0);
        inline for (0..unroll) |step| {
            const chunk: Lanes = bytes[index + step * lanes ..][0..lanes].*;
            folded |= chunk;
        }
        if (@reduce(.Or, folded) != 0) return false;
    }
    for (bytes[index..]) |byte| if (byte != 0) return false;
    return true;
}

/// A run of consecutive set bits: bits `start` up to but excluding `end`.
pub const Run = struct {
    start: u64,
    end: u64,
};

/// Iterates runs of set bits in a little-endian bitmap, where bit `i` is
/// bit `i % 8` of byte `i / 8`, as in ext4 block bitmaps. Each step skips
/// a whole 64-bit word of clear or set bits with one `@ctz`.
pub const SetRuns = struct {
    bitmap: []const u8,
    bit_count: u64,
    position: u64 = 0,

    /// Iterates the first `bit_count` bits of `bitmap`.
    pub fn init(bitmap: []const u8, bit_count: u64) SetRuns {
        std.debug.assert(bit_count <= @as(u64, bitmap.len) * 8);
        return .{ .bitmap = bitmap, .bit_count = bit_count };
    }

    pub fn next(self: *SetRuns) ?Run {
        const start = self.find(self.position, true);
        if (start >= self.bit_count) return null;
        const end = self.find(start, false);
        self.position = end;
        return .{ .start = start, .end = end };
    }

    /// Index of the first bit at or after `from` equal to `set`, or
    /// `bit_count` when there is none.
    fn find(self: *const SetRuns, from: u64, comptime set: bool) u64 {
        var word_index = from / 64;
        var skip: u6 = @intCast(from % 64);
        while (word_index * 64 < self.bit_count) : ({
            word_index += 1;
            skip = 0;
        }) {
            var word = self.loadWord(word_index);
            if (!set) word = ~word;
            word &= ~@as(u64, 0) << skip;
            if (word != 0) return @min(word_index * 64 + @ctz(word), self.bit_count);
        }
        return self.bit_count;
    }

    fn loadWord(self: *const SetRuns, word_index: u64) u64 {
        const offset: usize = @intCast(word_index * 8);
        if (offset + 8 <= self.bitmap.len) return std.mem.readInt(u64, self.bitmap[offset..][0..8], .little);
        var tail: [8]u8 = @splat(0);
        const available = self.bitmap.len - offset;
        @memcpy(tail[0..available], self.bitmap[offset..]);
        return std.mem.readInt(u64, &tail, .little);
    }
};

test "isZero agrees with a byte loop around vector boundaries" {
    var buffer: [lanes * unroll * 3 + 7]u8 = @splat(0);
    try std.testing.expect(isZero(&buffer));
    try std.testing.expect(isZero(buffer[0..0]));
    for (0..buffer.len) |index| {
        buffer[index] = 1;
        try std.testing.expect(!isZero(&buffer));
        try std.testing.expect(isZero(buffer[0..index]));
        buffer[index] = 0;
    }
}

test "SetRuns matches a bit-by-bit scan" {
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    var bitmap: [53]u8 = undefined;
    for (0..200) |_| {
        random.bytes(&bitmap);
        // Sparse and dense patterns exercise long runs across words.
        if (random.boolean()) for (&bitmap) |*byte| {
            byte.* = if (random.uintLessThan(u8, 4) == 0) byte.* else 0;
        };
        const bit_count = random.uintAtMost(u64, bitmap.len * 8);

        var runs = SetRuns.init(&bitmap, bit_count);
        var bit: u64 = 0;
        while (bit < bit_count) {
            if (!isSet(&bitmap, bit)) {
                bit += 1;
                continue;
            }
            var end = bit;
            while (end < bit_count and isSet(&bitmap, end)) end += 1;
            try std.testing.expectEqual(Run{ .start = bit, .end = end }, runs.next().?);
            bit = end;
        }
        try std.testing.expectEqual(@as(?Run, null), runs.next());
    }
}

fn isSet(bitmap: []const u8, bit: u64) bool {
    return bitmap[@intCast(bit / 8)] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
}
