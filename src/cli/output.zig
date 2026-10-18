//! CLI output generated from types.
//!
//! Library results are copied into view structs whose fields fix the
//! output's keys, order, and formats: a `Bytes` field is scaled to binary
//! units under `-h` and stays a plain number in JSON. JSON is
//! `std.json.Stringify` over a view, and text walks the same fields with
//! `writeFields`, so the two cannot disagree about what is shown.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const openetcher = @import("openetcher");

/// A count of bytes. Declaring a view field `Bytes` rather than an integer
/// is what makes `-h` scale it.
pub const Bytes = enum(u64) {
    _,

    pub fn of(count: u64) Bytes {
        return @fromBackingInt(count);
    }

    /// Formats as the plain count, or in binary units when `humanize` is set.
    pub fn fmt(self: Bytes, humanize: bool) Formatter {
        return .{ .bytes = self, .humanize = humanize };
    }

    pub const Formatter = struct {
        bytes: Bytes,
        humanize: bool,

        pub fn format(self: Formatter, writer: *Writer) Writer.Error!void {
            const count = @backingInt(self.bytes);
            if (!self.humanize) return writer.print("{d}", .{count});

            const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
            var scaled = count;
            var remainder: u64 = 0;
            var unit: usize = 0;
            while (scaled >= 1024 and unit + 1 < units.len) {
                remainder = scaled % 1024;
                scaled /= 1024;
                unit += 1;
            }
            // One truncated decimal from the last division, omitted when zero.
            const tenths = (remainder * 10) / 1024;
            if (tenths == 0) {
                try writer.print("{d} {s}", .{ scaled, units[unit] });
            } else {
                try writer.print("{d}.{d} {s}", .{ scaled, tenths, units[unit] });
            }
        }
    };

    pub fn jsonStringify(self: Bytes, jw: anytype) !void {
        try jw.write(@backingInt(self));
    }
};

/// `value` in binary units, for callers that need the text as a slice.
pub fn formatBytes(buffer: []u8, value: u64) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(buffer, "{f}", .{Bytes.of(value).fmt(true)});
}

/// An MBR partition type byte: hex in text, as partitioning tools show it,
/// and a number in JSON.
pub const PartitionType = enum(u8) {
    _,

    pub fn format(self: PartitionType, writer: *Writer) Writer.Error!void {
        try writer.print("0x{x:0>2}", .{@backingInt(self)});
    }

    pub fn jsonStringify(self: PartitionType, jw: anytype) !void {
        try jw.write(@backingInt(self));
    }
};

pub const InfoView = struct {
    image_size: Bytes,
    compression: openetcher.Compression,
    encoded_size: ?Bytes,
    layout: openetcher.Info.Layout,
    filesystem: ?openetcher.Info.Filesystem,
    block_size: ?Bytes,
    used_bytes: ?Bytes,
    skipped_bytes: ?Bytes,
    range_count: ?usize,
    partitions: []const PartitionView,
};

pub const PartitionView = struct {
    index: u8,
    partition_type: PartitionType,
    filesystem: openetcher.Info.Filesystem,
    supported: bool,
    start_offset: Bytes,
    size: Bytes,
    reason: ?openetcher.Info.Reason,
    block_size: ?Bytes,
    used_bytes: ?Bytes,
    skipped_bytes: ?Bytes,
    range_count: ?usize,
};

pub const DiskView = struct {
    id: []const u8,
    device: []const u8,
    raw: []const u8,
    display_name: []const u8,
    description: []const u8,
    bus_type: []const u8,
    location: ?[]const u8,
    size: Bytes,
    block_size: Bytes,
    logical_block_size: Bytes,
    partition_table: ?openetcher.DevicePartitionTable,
    protected: bool,
    system: bool,
    removable: bool,
    read_only: bool,
    virtual: bool,
    card: bool,
    usb: bool,
    scsi: bool,
    raid: bool,
    mountpoints: []const openetcher.DeviceMountPoint,

    pub const source_names = .{ .device = "device_path", .raw = "raw_path", .mountpoints = "mount_points" };
};

/// A plan with the totals a reader wants before the ranges.
pub const PlanView = struct {
    image_size: Bytes,
    planned_bytes: Bytes,
    skipped_bytes: Bytes,
    range_count: usize,
    ranges: []const RangeView,

    pub fn init(allocator: Allocator, plan: openetcher.FlashPlan) Allocator.Error!PlanView {
        const ranges = try allocator.alloc(RangeView, plan.ranges.len);
        var planned_bytes: u64 = 0;
        for (ranges, plan.ranges) |*range_view, range| {
            range_view.* = .{ .offset = .of(range.offset), .length = .of(range.length), .end = .of(range.end()) };
            planned_bytes += range.length;
        }
        return .{
            .image_size = .of(plan.image_size),
            .planned_bytes = .of(planned_bytes),
            .skipped_bytes = .of(plan.image_size - planned_bytes),
            .range_count = plan.ranges.len,
            .ranges = ranges,
        };
    }
};

pub const RangeView = struct {
    offset: Bytes,
    length: Bytes,
    end: Bytes,
};

/// Converts a library value to the view type `View`, or a slice of them to a
/// slice of views. Each view field takes the source field of the same name,
/// or the one `View.source_names` maps it to: integers become `Bytes` or
/// other integer-backed enums, and nested structs and slices convert
/// recursively. Every source field must reach the view, so a field added to
/// a library struct fails the build here rather than silently going missing
/// from the output.
pub fn view(comptime View: type, allocator: Allocator, value: anytype) Allocator.Error!View {
    const Source = @TypeOf(value);
    if (Source == View) return value;
    switch (@typeInfo(View)) {
        .optional => |optional| return if (value) |present| try view(optional.child, allocator, present) else null,
        .@"enum" => return @fromBackingInt(value),
        .pointer => |pointer| {
            if (pointer.child == std.meta.Elem(Source)) return value;
            const items = try allocator.alloc(pointer.child, value.len);
            for (items, value) |*item, source_item| item.* = try view(pointer.child, allocator, source_item);
            return items;
        },
        .@"struct" => {
            comptime checkCoverage(View, Source);
            var result: View = undefined;
            inline for (comptime std.meta.fieldNames(View), comptime std.meta.fieldTypes(View)) |name, T| {
                @field(result, name) = try view(T, allocator, @field(value, sourceName(View, name)));
            }
            return result;
        },
        else => @compileError("no view conversion from " ++ @typeName(Source) ++ " to " ++ @typeName(View)),
    }
}

fn sourceName(comptime View: type, comptime name: []const u8) []const u8 {
    if (@hasDecl(View, "source_names") and @hasField(@TypeOf(View.source_names), name)) {
        return @field(View.source_names, name);
    }
    return name;
}

fn checkCoverage(comptime View: type, comptime Source: type) void {
    for (std.meta.fieldNames(Source)) |source_name| {
        for (std.meta.fieldNames(View)) |name| {
            if (std.mem.eql(u8, sourceName(View, name), source_name)) break;
        } else @compileError(@typeName(View) ++ " does not show " ++ @typeName(Source) ++ "." ++ source_name ++ "; add a field for it");
    }
}

/// Writes `value` as indented JSON with null fields left out.
pub fn writeJson(writer: *Writer, value: anytype) Writer.Error!void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

pub fn writeInfoText(writer: *Writer, info: InfoView, humanize: bool) Writer.Error!void {
    try writeFields(writer, info, humanize, .{ .skip = &.{"partitions"} });
    if (info.partitions.len == 0) return;
    try writer.writeAll("partitions:\n");
    for (info.partitions) |partition| {
        try writer.print("  {d}:", .{partition.index});
        try writeFields(writer, partition, humanize, .{
            .which = .required,
            .skip = &.{"index"},
            .labels = &.{ .{ "partition_type", "type" }, .{ "start_offset", "start" } },
            .prefix = " ",
            .separator = "=",
            .terminator = "",
        });
        try writer.writeByte('\n');
        try writeFields(writer, partition, humanize, .{ .which = .optional, .prefix = "     ", .separator = "=" });
    }
}

pub fn writePlanText(writer: *Writer, plan: PlanView, humanize: bool) Writer.Error!void {
    try writeFields(writer, plan, humanize, .{ .skip = &.{"ranges"} });
    try writer.writeAll("ranges:\n");
    for (plan.ranges, 0..) |range, index| {
        try writer.print("  {d}:", .{index});
        try writeFields(writer, range, humanize, .{ .prefix = " ", .separator = "=", .terminator = "" });
        try writer.writeByte('\n');
    }
}

/// `all` says whether internal disks were listed too, which changes what an
/// empty list means.
pub fn writeDisksText(writer: *Writer, disks: []const DiskView, all: bool, humanize: bool) Writer.Error!void {
    if (disks.len == 0) {
        try writer.writeAll(if (all) "no disks found\n" else "no candidate disks found\n");
        return;
    }
    for (disks, 0..) |disk, index| {
        try writer.print("{d}: {s}\n", .{ index, disk.device });
        try writeFields(writer, disk, humanize, .{ .prefix = "   ", .skip = &.{ "device", "display_name", "mountpoints" } });
        try writer.writeAll("   mountpoints:");
        if (disk.mountpoints.len == 0) try writer.writeAll(" none");
        for (disk.mountpoints) |mount_point| {
            try writer.print(" {s}", .{mount_point.path});
            if (mount_point.label) |text| try writer.print(" ({s})", .{text});
        }
        try writer.writeByte('\n');
    }
}

/// How `writeFields` lays out each field: `prefix`, label, `separator`,
/// value, `terminator`.
const Layout = struct {
    which: enum { all, required, optional } = .all,
    skip: []const []const u8 = &.{},
    /// Pairs of field name and the label text shows instead.
    labels: []const [2][]const u8 = &.{},
    prefix: []const u8 = "",
    separator: []const u8 = ": ",
    terminator: []const u8 = "\n",
};

/// Writes the fields of the struct `value` in declaration order, leaving out
/// null optionals. Each value is formatted by its type, see `writeValue`.
fn writeFields(writer: *Writer, value: anytype, humanize: bool, comptime layout: Layout) Writer.Error!void {
    comptime {
        for (layout.skip) |name| checkField(@TypeOf(value), name);
        for (layout.labels) |pair| checkField(@TypeOf(value), pair[0]);
    }
    inline for (comptime std.meta.fieldNames(@TypeOf(value)), comptime std.meta.fieldTypes(@TypeOf(value))) |name, T| {
        const optional = @typeInfo(T) == .optional;
        const shown = comptime !contains(layout.skip, name) and switch (layout.which) {
            .all => true,
            .required => !optional,
            .optional => optional,
        };
        if (shown) {
            const field = @field(value, name);
            if (if (optional) field != null else true) {
                try writer.writeAll(layout.prefix);
                try writer.writeAll(comptime label(layout, name));
                try writer.writeAll(layout.separator);
                try writeValue(writer, if (optional) field.? else field, humanize);
                try writer.writeAll(layout.terminator);
            }
        }
    }
}

fn writeValue(writer: *Writer, value: anytype, humanize: bool) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == Bytes) return writer.print("{f}", .{value.fmt(humanize)});
    if (T == []const u8) return writer.writeAll(value);
    if (comptime std.meta.hasMethod(T, "format")) return writer.print("{f}", .{value});
    switch (@typeInfo(T)) {
        .@"enum" => try writer.print("{t}", .{value}),
        .bool, .int => try writer.print("{}", .{value}),
        else => @compileError("no text format for " ++ @typeName(T)),
    }
}

fn checkField(comptime T: type, comptime name: []const u8) void {
    if (!@hasField(T, name)) @compileError(@typeName(T) ++ " has no field ." ++ name ++ " to lay out");
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn label(comptime layout: Layout, comptime name: []const u8) []const u8 {
    for (layout.labels) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
    return name;
}

const test_partitions = [_]openetcher.Info.PartitionInfo{
    .{ .index = 1, .start_offset = 512, .size = 3 * 1024 * 1024 / 2, .partition_type = 0x0c, .filesystem = .fat32, .supported = true, .block_size = 4096, .used_bytes = 8192, .skipped_bytes = 3 * 1024 * 1024 / 2 - 8192, .range_count = 2 },
    .{ .index = 2, .start_offset = 1024 * 1024, .size = 2048, .partition_type = 0x83, .filesystem = .empty, .supported = false, .reason = .empty },
};
const test_info: openetcher.Info = .{ .image_size = 2 * 1024 * 1024, .layout = .mbr, .partitions = &test_partitions };

test "info JSON keeps byte counts as numbers and leaves out nulls" {
    const info_view = try view(InfoView, std.testing.allocator, test_info);
    defer std.testing.allocator.free(info_view.partitions);
    var buffer: [2048]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try writeJson(&writer, info_view);
    try std.testing.expectEqualStrings(
        \\{
        \\  "image_size": 2097152,
        \\  "compression": "none",
        \\  "layout": "mbr",
        \\  "partitions": [
        \\    {
        \\      "index": 1,
        \\      "partition_type": 12,
        \\      "filesystem": "fat32",
        \\      "supported": true,
        \\      "start_offset": 512,
        \\      "size": 1572864,
        \\      "block_size": 4096,
        \\      "used_bytes": 8192,
        \\      "skipped_bytes": 1564672,
        \\      "range_count": 2
        \\    },
        \\    {
        \\      "index": 2,
        \\      "partition_type": 131,
        \\      "filesystem": "empty",
        \\      "supported": false,
        \\      "start_offset": 1048576,
        \\      "size": 2048,
        \\      "reason": "partition appears empty"
        \\    }
        \\  ]
        \\}
        \\
    , writer.buffered());
}

test "info text humanizes exactly the byte fields" {
    const info_view = try view(InfoView, std.testing.allocator, test_info);
    defer std.testing.allocator.free(info_view.partitions);
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try writeInfoText(&writer, info_view, false);
    try writeInfoText(&writer, info_view, true);
    try std.testing.expectEqualStrings(
        \\image_size: 2097152
        \\compression: none
        \\layout: mbr
        \\partitions:
        \\  1: type=0x0c filesystem=fat32 supported=true start=512 size=1572864
        \\     block_size=4096
        \\     used_bytes=8192
        \\     skipped_bytes=1564672
        \\     range_count=2
        \\  2: type=0x83 filesystem=empty supported=false start=1048576 size=2048
        \\     reason=partition appears empty
        \\image_size: 2 MiB
        \\compression: none
        \\layout: mbr
        \\partitions:
        \\  1: type=0x0c filesystem=fat32 supported=true start=512 B size=1.5 MiB
        \\     block_size=4 KiB
        \\     used_bytes=8 KiB
        \\     skipped_bytes=1.4 MiB
        \\     range_count=2
        \\  2: type=0x83 filesystem=empty supported=false start=1 MiB size=2 KiB
        \\     reason=partition appears empty
        \\
    , writer.buffered());
}

test "plan output carries the derived totals" {
    var ranges = [_]openetcher.ByteRange{ .{ .offset = 0, .length = 1024 }, .{ .offset = 4096, .length = 512 } };
    const plan_view = try PlanView.init(std.testing.allocator, .{ .image_size = 8192, .ranges = &ranges });
    defer std.testing.allocator.free(plan_view.ranges);
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try writePlanText(&writer, plan_view, true);
    try std.json.Stringify.value(plan_view, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\image_size: 8 KiB
        \\planned_bytes: 1.5 KiB
        \\skipped_bytes: 6.5 KiB
        \\range_count: 2
        \\ranges:
        \\  0: offset=0 B length=1 KiB end=1 KiB
        \\  1: offset=4 KiB length=512 B end=4.5 KiB
        \\{"image_size":8192,"planned_bytes":1536,"skipped_bytes":6656,"range_count":2,"ranges":[{"offset":0,"length":1024,"end":1024},{"offset":4096,"length":512,"end":4608}]}
    , writer.buffered());
}

test "humanized byte counts truncate to one decimal" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1023 B", try formatBytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1 KiB", try formatBytes(&buffer, 1024 + 100));
    try std.testing.expectEqualStrings("9.9 MiB", try formatBytes(&buffer, 10 * 1024 * 1024 - 1));
    try std.testing.expectEqualStrings("2048 TiB", try formatBytes(&buffer, 2048 << 40));
}
