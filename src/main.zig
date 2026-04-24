const std = @import("std");

const openetcher = @import("openetcher");

const ProgressState = struct {
    writer: *std.Io.Writer,
    last_phase: ?openetcher.FlashPhase = null,
    last_line_len: usize = 0,

    fn update(context: *anyopaque, progress: openetcher.FlashProgress) !void {
        const self: *ProgressState = @ptrCast(@alignCast(context));
        const label = switch (progress.phase) {
            .flash => "flash",
            .verify => "verify",
        };
        const percent = if (progress.total_bytes == 0)
            100
        else
            @min(100, @as(u64, @intCast((progress.completed_bytes * 100) / progress.total_bytes)));

        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{s}: {}/{} bytes ({}%)", .{
            label,
            progress.completed_bytes,
            progress.total_bytes,
            percent,
        });

        if (self.last_phase != null and self.last_phase.? != progress.phase) {
            try self.writer.writeByte('\n');
            self.last_line_len = 0;
        }

        try self.writer.writeByte('\r');
        try self.writer.writeAll(line);
        if (line.len < self.last_line_len) {
            var pad_len = self.last_line_len - line.len;
            while (pad_len > 0) : (pad_len -= 1) try self.writer.writeByte(' ');
            try self.writer.writeByte('\r');
            try self.writer.writeAll(line);
        }
        try self.writer.flush();

        self.last_phase = progress.phase;
        self.last_line_len = line.len;
    }

    fn finish(self: *ProgressState) !void {
        if (self.last_phase == null) return;
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }
};

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
        var info = openetcher.probeImageFromPath(arena, io, image_path) catch |err| {
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
        const plan = openetcher.planImageFlashFromPath(arena, io, image_path) catch |err| {
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

    if (std.mem.eql(u8, command, "disks")) {
        const parsed = parseListArgs(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };

        const disks = openetcher.device_api.listCandidateDisks(arena, io, .{ .include_system = parsed.include_system }) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer disks.deinit(arena);

        if (parsed.json) {
            try writeCandidateDisksJson(stdout, disks.items);
        } else {
            try writeCandidateDisks(stdout, disks.items, parsed.include_system);
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "flash")) {
        const parsed = parseFlashArgs(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };

        const target_path = switch (parsed.target) {
            .path => |path| path,
            .disk_id => |disk_id| openetcher.device_api.resolveDiskId(arena, io, disk_id, .{ .include_system = true }) catch |err| {
                try writeUserError(stderr, err);
                try stderr.flush();
                std.process.exit(1);
            },
        };

        const target_info = openetcher.device_api.probeTarget(arena, io, target_path) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer target_info.deinit(arena);

        if (!std.mem.eql(u8, target_info.requested_path, target_info.resolved_path)) {
            try stderr.print("normalized target: {s} -> {s}\n", .{ target_info.requested_path, target_info.resolved_path });
            try stderr.flush();
        }

        try stderr.print("preparing target: {s}\n", .{target_info.resolved_path});
        try stderr.flush();
        openetcher.device_api.prepareTargetPath(arena, io, target_path) catch |err| {
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };

        var progress = ProgressState{ .writer = stderr };
        const start_time = std.Io.Clock.awake.now(io);
        const report = openetcher.flashPlannedImage(arena, io, parsed.image_path, target_path, .{
            .prepare_target = false,
            .progress_handler = .{
                .context = &progress,
                .callback = ProgressState.update,
            },
        }) catch |err| {
            try progress.finish();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        try progress.finish();

        const elapsed = start_time.durationTo(std.Io.Clock.awake.now(io));
        const elapsed_ns: u64 = @intCast(@max(elapsed.nanoseconds, 1));
        const actual_bytes_per_second = bytesPerSecond(report.bytes_written, elapsed_ns);
        const effective_bytes_per_second = bytesPerSecond(report.image_size, elapsed_ns);

        try stdout.print("wrote {} bytes across {} ranges, skipped {} bytes\n", .{ report.bytes_written, report.range_count, report.bytes_skipped });
        var actual_speed_buffer: [32]u8 = undefined;
        var effective_speed_buffer: [32]u8 = undefined;
        const actual_speed = try formatBytesPerSecond(&actual_speed_buffer, actual_bytes_per_second);
        const effective_speed = try formatBytesPerSecond(&effective_speed_buffer, effective_bytes_per_second);
        try stdout.print("actual throughput: {s}/s\n", .{actual_speed});
        try stdout.print("effective throughput: {s}/s\n", .{effective_speed});
        try stdout.flush();
        return;
    }

    try writeUsage(stderr);
    try stderr.flush();
    std.process.exit(1);
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.print("usage:\n  openetcher info [--json] <image>\n  openetcher plan [--json] <image>\n  openetcher disks [--json] [--all]\n  openetcher flash <image> <device>\n  openetcher flash <image> --disk-id <id>\n", .{});
}

fn parseJsonFlag(args: []const []const u8) !bool {
    if (args.len == 1) return false;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--json")) return true;
    return error.InvalidArguments;
}

const ListArgs = struct {
    json: bool = false,
    include_system: bool = false,
};

const FlashArgs = struct {
    image_path: []const u8,
    target: union(enum) {
        path: []const u8,
        disk_id: []const u8,
    },
};

fn parseListArgs(args: []const []const u8) !ListArgs {
    var parsed: ListArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (parsed.json) return error.InvalidArguments;
            parsed.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (parsed.include_system) return error.InvalidArguments;
            parsed.include_system = true;
            continue;
        }
        return error.InvalidArguments;
    }
    return parsed;
}

fn parseFlashArgs(args: []const []const u8) !FlashArgs {
    if (args.len == 2) {
        return .{
            .image_path = args[0],
            .target = .{ .path = args[1] },
        };
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "--disk-id")) {
        return .{
            .image_path = args[0],
            .target = .{ .disk_id = args[2] },
        };
    }

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

fn writeCandidateDisks(writer: *std.Io.Writer, disks: []const openetcher.DeviceCandidateDisk, include_system: bool) !void {
    if (disks.len == 0) {
        if (include_system) {
            try writer.print("no disks found\n", .{});
        } else {
            try writer.print("no candidate disks found\n", .{});
        }
        return;
    }

    for (disks, 0..) |disk, index| {
        try writer.print("{}: {s}\n", .{ index, disk.device_path });
        try writer.print("   id: {s}\n", .{disk.id});
        try writer.print("   raw: {s}\n", .{disk.raw_path});
        try writer.print("   description: {s}\n", .{disk.description});
        try writer.print("   size: {}\n", .{disk.size});
        try writer.print("   system: {}\n", .{disk.system});
        try writer.print("   removable: {}\n", .{disk.removable});
        if (disk.mount_points.len == 0) {
            try writer.print("   mountpoints: none\n", .{});
        } else {
            try writer.print("   mountpoints:", .{});
            for (disk.mount_points) |mount_point| {
                try writer.print(" {s}", .{mount_point.path});
            }
            try writer.writeByte('\n');
        }
    }
}

fn writeCandidateDisksJson(writer: *std.Io.Writer, disks: []const openetcher.DeviceCandidateDisk) !void {
    try writer.print("[", .{});
    for (disks, 0..) |disk, index| {
        if (index != 0) try writer.print(",", .{});
        try writer.print("\n  {{\"id\": ", .{});
        try std.json.Stringify.value(disk.id, .{}, writer);
        try writer.print(", \"device\": ", .{});
        try std.json.Stringify.value(disk.device_path, .{}, writer);
        try writer.print(", \"raw\": ", .{});
        try std.json.Stringify.value(disk.raw_path, .{}, writer);
        try writer.print(", \"display_name\": ", .{});
        try std.json.Stringify.value(disk.display_name, .{}, writer);
        try writer.print(", \"description\": ", .{});
        try std.json.Stringify.value(disk.description, .{}, writer);
        try writer.print(", \"size\": {}, \"system\": {}, \"removable\": {}, \"mountpoints\": [", .{
            disk.size,
            disk.system,
            disk.removable,
        });
        for (disk.mount_points, 0..) |mount_point, mount_index| {
            if (mount_index != 0) try writer.print(",", .{});
            try writer.print("{{\"path\": ", .{});
            try std.json.Stringify.value(mount_point.path, .{}, writer);
            try writer.print("}}", .{});
        }
        try writer.print("]}}", .{});
    }
    try writer.print("\n]\n", .{});
}

fn writeUserError(writer: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.UnsupportedImageLayout => {
            try writer.print("unsupported image layout: only raw ext4 filesystem images are supported right now\n", .{});
        },
        error.UnsupportedPartitionFilesystem => {
            try writer.print("image contains unsupported partition filesystems; run `openetcher info <image>` for details\n", .{});
        },
        error.UnknownDiskId => {
            try writer.print("unknown disk id: run `openetcher disks` to list candidate ids\n", .{});
        },
        error.AmbiguousDiskId => {
            try writer.print("ambiguous disk id: run `openetcher disks --all --json` and choose a more specific target\n", .{});
        },
        else => {
            try writer.print("error: {t}\n", .{err});
        },
    }
}

fn bytesPerSecond(bytes: u64, elapsed_ns: u64) u64 {
    return @intCast((@as(u128, bytes) * std.time.ns_per_s) / elapsed_ns);
}

fn formatBytesPerSecond(buffer: []u8, value: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var scaled = value;
    var remainder: u64 = 0;
    var unit_index: usize = 0;

    while (scaled >= 1024 and unit_index + 1 < units.len) {
        remainder = scaled % 1024;
        scaled /= 1024;
        unit_index += 1;
    }

    if (unit_index == 0 or remainder == 0) {
        return std.fmt.bufPrint(buffer, "{} {s}", .{ scaled, units[unit_index] });
    }

    const decimal = (remainder * 10) / 1024;
    if (decimal == 0) {
        return std.fmt.bufPrint(buffer, "{} {s}", .{ scaled, units[unit_index] });
    }

    return std.fmt.bufPrint(buffer, "{}.{} {s}", .{ scaled, decimal, units[unit_index] });
}
