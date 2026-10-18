const std = @import("std");

const Syllable = enum {
    none,
    L,
    LV,
    LVT,
    V,
    T,
};

const syllable_mask: u4 = 0b0111;
const modern_jamo: u4 = 0b1000;
const block_size = 256;
const Block = [block_size]u4;

const Range = struct {
    first: u21 = std.math.maxInt(u21),
    last: u21 = 0,
    count: u21 = 0,

    fn add(range: *Range, cp: u21) void {
        range.first = @min(range.first, cp);
        range.last = @max(range.last, cp);
        range.count += 1;
    }

    fn validate(range: Range) !void {
        if (range.count == 0 or range.last - range.first + 1 != range.count)
            return error.NonContiguousHangulRange;
    }
};

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), k: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return std.mem.eql(u4, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var flat_map = std.AutoHashMap(u21, u4).init(allocator);
    defer flat_map.deinit();
    var syllable_range: Range = .{};

    // Process HangulSyllableType.txt
    var in_reader = std.Io.Reader.fixed(@embedFile("HangulSyllableType.txt"));
    while (in_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;

        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");
        var current_code: [2]u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        current_code = .{
                            try std.fmt.parseInt(u21, field[0..dots], 16),
                            try std.fmt.parseInt(u21, field[dots + 2 ..], 16),
                        };
                    } else {
                        const code = try std.fmt.parseInt(u21, field, 16);
                        current_code = .{ code, code };
                    }
                },
                1 => {
                    // Syllable type
                    const st: Syllable = std.meta.stringToEnum(Syllable, field) orelse .none;
                    for (current_code[0]..current_code[1] + 1) |cp_usize| {
                        const cp: u21 = @intCast(cp_usize);
                        try flat_map.put(cp, @intFromEnum(st));
                        if (st == .LV or st == .LVT) syllable_range.add(cp);
                    }
                },
                else => {},
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            return err;
        },
    }

    // Jamo.txt enumerates the modern jamo used by the algorithmic Hangul
    // composition and naming algorithms. Classify those entries with
    // HangulSyllableType.txt and retain that membership bit.
    var jamo_ranges = [_]Range{.{}} ** @typeInfo(Syllable).@"enum".fields.len;
    var jamo_reader = std.Io.Reader.fixed(@embedFile("Jamo.txt"));
    while (jamo_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;

        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse
            return error.InvalidJamoData;
        const cp_text = std.mem.trim(u8, line[0..semicolon], " ");
        const cp = try std.fmt.parseInt(u21, cp_text, 16);
        const entry = flat_map.getPtr(cp) orelse return error.InvalidJamoData;
        const st: Syllable = @enumFromInt(entry.* & syllable_mask);
        switch (st) {
            .L, .V, .T => {},
            else => return error.InvalidJamoData,
        }
        entry.* |= modern_jamo;
        jamo_ranges[@intFromEnum(st)].add(cp);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    const l_range = jamo_ranges[@intFromEnum(Syllable.L)];
    const v_range = jamo_ranges[@intFromEnum(Syllable.V)];
    const t_range = jamo_ranges[@intFromEnum(Syllable.T)];
    try l_range.validate();
    try v_range.validate();
    try t_range.validate();
    try syllable_range.validate();

    const t_count = t_range.count + 1;
    const n_count = v_range.count * t_count;
    if (syllable_range.count != l_range.count * n_count)
        return error.InvalidHangulData;

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.array_list.Managed(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.array_list.Managed(u4).init(allocator);
    defer stage2.deinit();

    var block: Block = @splat(0);
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const st = flat_map.get(cp) orelse 0;

        // Process block
        block[block_len] = st;
        block_len += 1;

        if (block_len < block_size and cp != 0x10ffff) continue;

        const gop = try blocks_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(stage2.items.len);
            try stage2.appendSlice(&block);
        }

        try stage1.append(gop.value_ptr.*);
        block_len = 0;
    }

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    var write_buf: [4096]u8 = undefined;
    var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer out_file.close(init.io);
    var writer = out_file.writer(init.io, &write_buf);

    try writer.interface.print(
        \\//! This file is auto-generated. Do not edit.
        \\
        \\pub const SBase: u21 = 0x{x};
        \\pub const LBase: u21 = 0x{x};
        \\pub const VBase: u21 = 0x{x};
        \\pub const TBase: u21 = 0x{x};
        \\pub const LCount: u21 = {};
        \\pub const VCount: u21 = {};
        \\pub const TCount: u21 = {};
        \\pub const NCount: u21 = {};
        \\pub const SCount: u21 = {};
        \\
        \\pub const s1: [{}]u16 = .{{
    , .{
        syllable_range.first,
        l_range.first,
        v_range.first,
        t_range.first - 1,
        l_range.count,
        v_range.count,
        t_count,
        n_count,
        syllable_range.count,
        stage1.items.len,
    });
    for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

    try writer.interface.print(
        \\
        \\}};
        \\
        \\pub const s2: [{}]u4 = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.flush();
}
