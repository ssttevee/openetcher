const builtin = @import("builtin");
const std = @import("std");

const openetcher = @import("openetcher");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try writeUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "info")) {
        const json = parseJsonFlag(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };
        const expected_len: usize = if (json) 4 else 3;
        if (args.len != expected_len) {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }

        const image_path = args[args.len - 1];
        var info = openetcher.probeImage(arena, io, image_path) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer info.deinit(arena);
        if (json) {
            try writeImageInfoJson(stdout, info);
        } else {
            try writeImageInfo(stdout, info);
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "plan")) {
        const json = parseJsonFlag(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };
        const expected_len: usize = if (json) 4 else 3;
        if (args.len != expected_len) {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }

        const image_path = args[args.len - 1];
        const plan = openetcher.planImageFlash(arena, io, image_path) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer plan.deinit(arena);
        if (json) {
            try writeFlashPlanJson(stdout, plan);
        } else {
            try writeFlashPlan(stdout, plan);
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "flash")) {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        if (args.len != 4) {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }

        const report = openetcher.flashPlannedImage(arena, io, args[2], args[3], .{}) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        try stdout.print("wrote {} bytes across {} ranges, skipped {} bytes\n", .{ report.bytes_written, report.range_count, report.bytes_skipped });
        try stdout.flush();
        return;
    }

    try writeUsage(stderr);
    try stderr.flush();
    std.process.exit(1);
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.print("usage:\n  openetcher info [--json] <image>\n  openetcher plan [--json] <image>\n  openetcher flash <image> <device>\n", .{});
}

fn parseJsonFlag(args: []const []const u8) !bool {
    if (args.len == 1) return false;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--json")) return true;
    return error.InvalidArguments;
}

fn writeImageInfo(writer: *std.Io.Writer, info: openetcher.ImageInfo) !void {
    try writer.print("image_size: {}\nlayout: {s}\n", .{ info.image_size, @tagName(info.layout) });

    if (info.filesystem) |filesystem| {
        try writer.print("filesystem: {s}\n", .{@tagName(filesystem)});
    }
    if (info.block_size) |block_size| {
        try writer.print("block_size: {}\n", .{block_size});
    }
    if (info.used_bytes) |used_bytes| {
        try writer.print("used_bytes: {}\n", .{used_bytes});
    }
    if (info.skipped_bytes) |skipped_bytes| {
        try writer.print("skipped_bytes: {}\n", .{skipped_bytes});
    }
    if (info.range_count) |range_count| {
        try writer.print("range_count: {}\n", .{range_count});
    }

    if (info.partitions.len == 0) return;
    try writer.print("partitions:\n", .{});
    for (info.partitions) |partition| {
        try writer.print("  {}: type=0x{x:0>2} filesystem={s} supported={} start={} size={}\n", .{
            partition.index,
            partition.partition_type,
            @tagName(partition.filesystem),
            partition.supported,
            partition.start_offset,
            partition.size,
        });
        if (partition.reason) |reason| {
            try writer.print("     reason={s}\n", .{reason});
        }
        if (partition.block_size) |block_size| {
            try writer.print("     block_size={}\n", .{block_size});
        }
        if (partition.used_bytes) |used_bytes| {
            try writer.print("     used_bytes={}\n", .{used_bytes});
        }
        if (partition.skipped_bytes) |skipped_bytes| {
            try writer.print("     skipped_bytes={}\n", .{skipped_bytes});
        }
        if (partition.range_count) |range_count| {
            try writer.print("     range_count={}\n", .{range_count});
        }
    }
}

fn writeImageInfoJson(writer: *std.Io.Writer, info: openetcher.ImageInfo) !void {
    try writer.print("{{\n  \"image_size\": {},\n  \"layout\": ", .{info.image_size});
    try std.json.Stringify.value(@tagName(info.layout), .{}, writer);
    try writer.writeByte('\n');

    if (info.filesystem) |filesystem| {
        try writer.print("  ,\"filesystem\": ", .{});
        try std.json.Stringify.value(@tagName(filesystem), .{}, writer);
        try writer.writeByte('\n');
    }
    if (info.block_size) |block_size| {
        try writer.print("  ,\"block_size\": {}\n", .{block_size});
    }
    if (info.used_bytes) |used_bytes| {
        try writer.print("  ,\"used_bytes\": {}\n", .{used_bytes});
    }
    if (info.skipped_bytes) |skipped_bytes| {
        try writer.print("  ,\"skipped_bytes\": {}\n", .{skipped_bytes});
    }
    if (info.range_count) |range_count| {
        try writer.print("  ,\"range_count\": {}\n", .{range_count});
    }

    try writer.print("  ,\"partitions\": [", .{});
    for (info.partitions, 0..) |partition, index| {
        if (index != 0) try writer.print(",", .{});
        try writer.print("\n    {{\"index\": {}, \"partition_type\": {}, \"filesystem\": ", .{
            partition.index,
            partition.partition_type,
        });
        try std.json.Stringify.value(@tagName(partition.filesystem), .{}, writer);
        try writer.print(", \"supported\": {}, \"start_offset\": {}, \"size\": {}", .{
            partition.supported,
            partition.start_offset,
            partition.size,
        });
        if (partition.reason) |reason| {
            try writer.print(", \"reason\": ", .{});
            try std.json.Stringify.value(reason, .{}, writer);
        }
        if (partition.block_size) |block_size| {
            try writer.print(", \"block_size\": {}", .{block_size});
        }
        if (partition.used_bytes) |used_bytes| {
            try writer.print(", \"used_bytes\": {}", .{used_bytes});
        }
        if (partition.skipped_bytes) |skipped_bytes| {
            try writer.print(", \"skipped_bytes\": {}", .{skipped_bytes});
        }
        if (partition.range_count) |range_count| {
            try writer.print(", \"range_count\": {}", .{range_count});
        }
        try writer.print("}}", .{});
    }
    try writer.print("\n  ]\n}}\n", .{});
}

fn writeFlashPlan(writer: *std.Io.Writer, plan: openetcher.FlashPlan) !void {
    var planned_bytes: u64 = 0;
    for (plan.ranges) |segment| planned_bytes += segment.length;

    try writer.print("image_size: {}\nplanned_bytes: {}\nskipped_bytes: {}\nrange_count: {}\nranges:\n", .{
        plan.image_size,
        planned_bytes,
        plan.image_size - planned_bytes,
        plan.ranges.len,
    });

    for (plan.ranges, 0..) |segment, index| {
        try writer.print("  {}: offset={} length={} end={}\n", .{
            index,
            segment.offset,
            segment.length,
            segment.end(),
        });
    }
}

fn writeFlashPlanJson(writer: *std.Io.Writer, plan: openetcher.FlashPlan) !void {
    var planned_bytes: u64 = 0;
    for (plan.ranges) |segment| planned_bytes += segment.length;

    try writer.print("{{\n  \"image_size\": {},\n  \"planned_bytes\": {},\n  \"skipped_bytes\": {},\n  \"range_count\": {},\n  \"ranges\": [", .{
        plan.image_size,
        planned_bytes,
        plan.image_size - planned_bytes,
        plan.ranges.len,
    });

    for (plan.ranges, 0..) |segment, index| {
        if (index != 0) try writer.print(",", .{});
        try writer.print("\n    {{\"offset\": {}, \"length\": {}, \"end\": {}}}", .{
            segment.offset,
            segment.length,
            segment.end(),
        });
    }

    try writer.print("\n  ]\n}}\n", .{});
}

fn writeUserError(writer: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.UnsupportedImageLayout => {
            try writer.print("unsupported image layout: only raw ext4 filesystem images are supported right now\n", .{});
        },
        error.UnsupportedPartitionFilesystem => {
            try writer.print("image contains unsupported partition filesystems; run `openetcher info <image>` for details\n", .{});
        },
        else => {
            try writer.print("error: {t}\n", .{err});
        },
    }
}
