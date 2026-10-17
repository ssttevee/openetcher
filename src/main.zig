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
        const parsed = parseOutputArgs(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };

        const image_path = parsed.image_path;
        // Probing spools compressed images, which can take minutes.
        const progress = startProgress(io);
        var image_source = openetcher.openImageSourceFromPath(arena, io, image_path, .{ .spool_dir = parsed.spool_dir orelse defaultSpoolDir(init.environ_map), .progress = progress }) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer image_source.deinit();
        var info = openetcher.probeImageSource(arena, io, &image_source, .{}) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer info.deinit(arena);
        progress.end();
        if (parsed.json) {
            try writeImageInfoJson(stdout, info);
        } else {
            try writeImageInfo(stdout, info, parsed.humanize);
        }
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "plan")) {
        const parsed = parseOutputArgs(args[2..]) catch {
            try writeUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        };

        const image_path = parsed.image_path;
        // Planning spools compressed images, which can take minutes.
        const progress = startProgress(io);
        var image_source = openetcher.openImageSourceFromPath(arena, io, image_path, .{ .spool_dir = parsed.spool_dir orelse defaultSpoolDir(init.environ_map), .progress = progress }) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer image_source.deinit();
        const plan = openetcher.planImageFlashSource(arena, io, &image_source, .{}) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer plan.deinit(arena);
        progress.end();
        if (parsed.json) {
            try writeFlashPlanJson(stdout, plan);
        } else {
            try writeFlashPlan(stdout, plan, parsed.humanize);
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
            try writeCandidateDisks(stdout, disks.items, parsed.include_system, parsed.humanize);
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

        if (!parsed.force) {
            const disk = openetcher.device_api.lookupDiskByPath(arena, io, target_path, .{ .include_system = true }) catch |err| {
                try writeUserError(stderr, err);
                try stderr.flush();
                std.process.exit(1);
            };
            if (disk) |candidate| {
                defer candidate.deinit(arena);
                if (candidate.protected) {
                    try writeUserError(stderr, error.ProtectedTargetRequiresForce);
                    try stderr.flush();
                    std.process.exit(1);
                }
            }
        }

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

        const progress = startProgress(io);
        const start_time = std.Io.Clock.awake.now(io);
        var image_source = openetcher.openImageSourceFromPath(arena, io, parsed.image_path, .{ .spool_dir = parsed.spool_dir orelse defaultSpoolDir(init.environ_map), .progress = progress }) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer image_source.deinit();
        const report = openetcher.flashSource(arena, io, &image_source, target_path, .{
            .prepare_target = false,
            .strategy = if (parsed.force) .force_full_streaming else .planned_sparse,
            .progress = progress,
        }) catch |err| {
            progress.end();
            try writeUserError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        progress.end();

        const elapsed = start_time.durationTo(std.Io.Clock.awake.now(io));
        const elapsed_ns: u64 = @intCast(@max(elapsed.nanoseconds, 1));
        const actual_bytes_per_second = bytesPerSecond(report.bytes_written, elapsed_ns);
        const effective_bytes_per_second = bytesPerSecond(report.image_size, elapsed_ns);

        try stdout.print("wrote ", .{});
        try writeByteValue(stdout, report.bytes_written, parsed.humanize);
        if (!parsed.humanize) try stdout.print(" bytes", .{});
        try stdout.print(" across {} ranges, skipped ", .{report.range_count});
        try writeByteValue(stdout, report.bytes_skipped, parsed.humanize);
        if (!parsed.humanize) try stdout.print(" bytes", .{});
        try stdout.writeByte('\n');
        var actual_speed_buffer: [32]u8 = undefined;
        var effective_speed_buffer: [32]u8 = undefined;
        const actual_speed = try formatBytes(&actual_speed_buffer, actual_bytes_per_second);
        const effective_speed = try formatBytes(&effective_speed_buffer, effective_bytes_per_second);
        try stdout.print("actual throughput: {s}/s\n", .{actual_speed});
        try stdout.print("effective throughput: {s}/s\n", .{effective_speed});
        try stdout.flush();
        return;
    }

    try writeUsage(stderr);
    try stderr.flush();
    std.process.exit(1);
}

/// Starts the progress display on stderr. It draws only when stderr is a
/// terminal, and forwards to a parent process instead when `ZIG_PROGRESS`
/// is set. End the returned node before writing anything else to stderr,
/// since ending it erases the display.
fn startProgress(io: std.Io) std.Progress.Node {
    return std.Progress.start(io, .{});
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.print("usage:\n  openetcher info [-h] [--json] [--spool-dir <dir>] <image>\n  openetcher plan [-h] [--json] [--spool-dir <dir>] <image>\n  openetcher disks [-h] [--json] [--all]\n  openetcher flash [-h] [--force] [--spool-dir <dir>] <image> <device>\n  openetcher flash [-h] [--force] [--spool-dir <dir>] <image> --disk-id <id>\n\ncompressed images are decoded once into --spool-dir (default: $TMPDIR)\n", .{});
}

/// Directory for decoded copies of compressed images, from the usual
/// temporary-directory variables. Null falls back to the library default.
fn defaultSpoolDir(environ: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |name| {
        if (environ.get(name)) |value| if (value.len != 0) return value;
    }
    return null;
}

const OutputArgs = struct {
    image_path: []const u8,
    json: bool = false,
    humanize: bool = false,
    spool_dir: ?[]const u8 = null,
};

fn parseOutputArgs(args: []const []const u8) !OutputArgs {
    var image_path: ?[]const u8 = null;
    var json = false;
    var humanize = false;
    var spool_dir: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--spool-dir")) {
            if (spool_dir != null or index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            spool_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (json) return error.InvalidArguments;
            json = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            if (humanize) return error.InvalidArguments;
            humanize = true;
        } else if (image_path == null) {
            image_path = arg;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .image_path = image_path orelse return error.InvalidArguments,
        .json = json,
        .humanize = humanize,
        .spool_dir = spool_dir,
    };
}

const ListArgs = struct {
    json: bool = false,
    humanize: bool = false,
    include_system: bool = false,
};

const FlashArgs = struct {
    image_path: []const u8,
    humanize: bool = false,
    force: bool = false,
    spool_dir: ?[]const u8 = null,
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
        if (std.mem.eql(u8, arg, "-h")) {
            if (parsed.humanize) return error.InvalidArguments;
            parsed.humanize = true;
            continue;
        }
        return error.InvalidArguments;
    }
    return parsed;
}

fn parseFlashArgs(args: []const []const u8) !FlashArgs {
    var image_path: ?[]const u8 = null;
    var device_path: ?[]const u8 = null;
    var disk_id: ?[]const u8 = null;
    var humanize = false;
    var force = false;
    var spool_dir: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h")) {
            if (humanize) return error.InvalidArguments;
            humanize = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            if (force) return error.InvalidArguments;
            force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--spool-dir")) {
            if (spool_dir != null or index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            spool_dir = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--disk-id")) {
            if (disk_id != null or index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            disk_id = args[index];
            continue;
        }
        if (image_path == null) {
            image_path = arg;
        } else if (device_path == null) {
            device_path = arg;
        } else {
            return error.InvalidArguments;
        }
    }

    const image = image_path orelse return error.InvalidArguments;
    if (disk_id) |id| {
        if (device_path != null) return error.InvalidArguments;
        return .{
            .image_path = image,
            .humanize = humanize,
            .force = force,
            .spool_dir = spool_dir,
            .target = .{ .disk_id = id },
        };
    }
    return .{
        .image_path = image,
        .humanize = humanize,
        .force = force,
        .spool_dir = spool_dir,
        .target = .{ .path = device_path orelse return error.InvalidArguments },
    };
}

fn writeImageInfo(writer: *std.Io.Writer, info: openetcher.ImageInfo, humanize: bool) !void {
    try writeByteField(writer, "image_size: ", info.image_size, humanize);
    try writer.print("layout: {s}\ncompression: {s}\n", .{ @tagName(info.layout), @tagName(info.compression) });
    if (info.encoded_size) |encoded_size| {
        try writeByteField(writer, "encoded_size: ", encoded_size, humanize);
    }

    if (info.filesystem) |filesystem| {
        try writer.print("filesystem: {s}\n", .{@tagName(filesystem)});
    }
    if (info.block_size) |block_size| {
        try writeByteField(writer, "block_size: ", block_size, humanize);
    }
    if (info.used_bytes) |used_bytes| {
        try writeByteField(writer, "used_bytes: ", used_bytes, humanize);
    }
    if (info.skipped_bytes) |skipped_bytes| {
        try writeByteField(writer, "skipped_bytes: ", skipped_bytes, humanize);
    }
    if (info.range_count) |range_count| {
        try writer.print("range_count: {}\n", .{range_count});
    }

    if (info.partitions.len == 0) return;
    try writer.print("partitions:\n", .{});
    for (info.partitions) |partition| {
        try writer.print("  {}: type=0x{x:0>2} filesystem={s} supported={} start=", .{
            partition.index,
            partition.partition_type,
            @tagName(partition.filesystem),
            partition.supported,
        });
        try writeByteValue(writer, partition.start_offset, humanize);
        try writer.print(" size=", .{});
        try writeByteValue(writer, partition.size, humanize);
        try writer.writeByte('\n');
        if (partition.reason) |reason| {
            try writer.print("     reason={f}\n", .{reason});
        }
        if (partition.block_size) |block_size| {
            try writeByteField(writer, "     block_size=", block_size, humanize);
        }
        if (partition.used_bytes) |used_bytes| {
            try writeByteField(writer, "     used_bytes=", used_bytes, humanize);
        }
        if (partition.skipped_bytes) |skipped_bytes| {
            try writeByteField(writer, "     skipped_bytes=", skipped_bytes, humanize);
        }
        if (partition.range_count) |range_count| {
            try writer.print("     range_count={}\n", .{range_count});
        }
    }
}

fn writeByteField(writer: *std.Io.Writer, prefix: []const u8, value: u64, humanize: bool) !void {
    try writer.print("{s}", .{prefix});
    try writeByteValue(writer, value, humanize);
    try writer.writeByte('\n');
}

fn writeByteValue(writer: *std.Io.Writer, value: u64, humanize: bool) !void {
    if (!humanize) {
        try writer.print("{}", .{value});
        return;
    }

    var buffer: [32]u8 = undefined;
    const formatted = try formatBytes(&buffer, value);
    try writer.print("{s}", .{formatted});
}

fn writeImageInfoJson(writer: *std.Io.Writer, info: openetcher.ImageInfo) !void {
    try writer.print("{{\n  \"image_size\": {},\n  \"compression\": ", .{info.image_size});
    try std.json.Stringify.value(@tagName(info.compression), .{}, writer);
    try writer.writeByte('\n');
    if (info.encoded_size) |encoded_size| {
        try writer.print("  ,\"encoded_size\": {}\n", .{encoded_size});
    }
    try writer.print("  ,\"layout\": ", .{});
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

fn writeFlashPlan(writer: *std.Io.Writer, plan: openetcher.FlashPlan, humanize: bool) !void {
    var planned_bytes: u64 = 0;
    for (plan.ranges) |segment| planned_bytes += segment.length;

    try writeByteField(writer, "image_size: ", plan.image_size, humanize);
    try writeByteField(writer, "planned_bytes: ", planned_bytes, humanize);
    try writeByteField(writer, "skipped_bytes: ", plan.image_size - planned_bytes, humanize);
    try writer.print("range_count: {}\nranges:\n", .{plan.ranges.len});

    for (plan.ranges, 0..) |segment, index| {
        try writer.print("  {}: offset=", .{index});
        try writeByteValue(writer, segment.offset, humanize);
        try writer.print(" length=", .{});
        try writeByteValue(writer, segment.length, humanize);
        try writer.print(" end=", .{});
        try writeByteValue(writer, segment.end(), humanize);
        try writer.writeByte('\n');
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

fn writeCandidateDisks(writer: *std.Io.Writer, disks: []const openetcher.DeviceCandidateDisk, include_system: bool, humanize: bool) !void {
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
        try writeByteField(writer, "   size: ", disk.size, humanize);
        try writer.print("   protected: {}\n", .{disk.protected});
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
        try writer.print(", \"size\": {}, \"protected\": {}, \"system\": {}, \"removable\": {}, \"mountpoints\": [", .{
            disk.size,
            disk.protected,
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

fn ErrorSetOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}

/// Every error a command reports through `writeUserError`.
const CommandError = ErrorSetOf(openetcher.openImageSourceFromPath) ||
    ErrorSetOf(openetcher.probeImageSource) ||
    ErrorSetOf(openetcher.planImageFlashSource) ||
    ErrorSetOf(openetcher.flashSource) ||
    ErrorSetOf(openetcher.device_api.listCandidateDisks) ||
    ErrorSetOf(openetcher.device_api.resolveDiskId) ||
    ErrorSetOf(openetcher.device_api.lookupDiskByPath) ||
    ErrorSetOf(openetcher.device_api.probeTarget) ||
    ErrorSetOf(openetcher.device_api.prepareTargetPath) ||
    error{ProtectedTargetRequiresForce};

const ErrorText = struct {
    errors: type,
    text: []const u8,
    /// Appends the error name, for groups whose members are worth telling
    /// apart.
    show_name: bool = false,
};

/// What the CLI prints for each error. Every member of `CommandError` must
/// appear in exactly one entry or the build fails, so a new library error
/// cannot reach users without a message.
const error_texts = [_]ErrorText{
    .{ .errors = error{UnsupportedPartitionFilesystem}, .text = "image contains unsupported partition filesystems; run `openetcher info <image>` for details, or flash with --force to write the whole image" },
    .{ .errors = error{UnknownDiskId}, .text = "unknown disk id: run `openetcher disks` to list candidate ids" },
    .{ .errors = error{AmbiguousDiskId}, .text = "ambiguous disk id: run `openetcher disks --all --json` and choose a more specific target" },
    .{ .errors = error{ProtectedTargetRequiresForce}, .text = "refusing to write a protected system disk without --force" },
    .{ .errors = error{Bzip2Unavailable}, .text = "bzip2 images are decompressed with the `bzip2` command, which was not found on PATH; install bzip2 or decompress the image first" },
    .{ .errors = error{SpoolDirectoryFull}, .text = "not enough space to decompress the image into the spool directory; pass --spool-dir <dir> on a larger volume, or flash with --force to stream without planning" },
    .{ .errors = error{SpoolDirectoryUnavailable}, .text = "cannot create the decompressed image in the spool directory; pass --spool-dir <dir> with a writable directory" },
    .{ .errors = error{UnsupportedImageSource}, .text = "the image must be a regular file" },
    .{ .errors = error{UnsupportedCompression}, .text = "the image uses an unsupported compression format" },
    .{ .errors = error{InvalidCompressedImage}, .text = "the compressed image is corrupt or truncated" },
    .{ .errors = error{DecompressedImageTooLarge}, .text = "the decompressed image is larger than the size limit" },
    .{ .errors = error{UnsupportedTargetType}, .text = "the target must be a regular file or a disk this platform can write" },
    .{ .errors = error{DestinationTooSmall}, .text = "the target is smaller than the image" },
    .{ .errors = error{VerificationFailed}, .text = "verification failed: the target does not read back what was written" },
    .{ .errors = error{DiskListFailed}, .text = "listing disks failed: `diskutil` reported an error" },
    .{ .errors = error{UnmountFailed}, .text = "could not unmount the target disk; close anything using it and retry" },
    .{ .errors = error{ AccessDenied, PermissionDenied }, .text = "permission denied; writing to a disk usually needs administrator rights" },
    .{ .errors = error{FileNotFound}, .text = "file not found" },
    .{ .errors = error{ReadOnlyFileSystem}, .text = "the target is read-only" },
    .{ .errors = error{ NoSpaceLeft, DiskQuota, FileTooBig }, .text = "no space left", .show_name = true },
    .{ .errors = error{ DeviceBusy, FileBusy, LockViolation, PipeBusy, AntivirusInterference }, .text = "the file or device is in use", .show_name = true },
    .{ .errors = error{ IsDir, NotDir, PathAlreadyExists, SymLinkLoop, NameTooLong, BadPathName, InvalidWtf8, NetworkNotFound }, .text = "invalid path", .show_name = true },
    .{
        .errors = error{
            InvalidImage,
            InvalidIso9660Image,
            ImageTruncated,
            InvalidPartitionTable,
            InvalidExt4Superblock,
            InvalidExt4GroupDescriptor,
            RangeOverflow,
            RangeOutsideRegion,
            RegionOutOfBounds,
            InvalidImageSize,
            UnexpectedEndOfImage,
            ImageSizeMismatch,
        },
        .text = "the image is corrupt or truncated",
        .show_name = true,
    },
    .{
        .errors = error{ UnsupportedExt4Feature, UnsupportedExt4CompatFeature, UnsupportedExt4IncompatFeature, UnsupportedExt4ReadOnlyFeature },
        .text = "the ext4 filesystem uses features the planner cannot handle; flash with --force to write the whole image",
        .show_name = true,
    },
    .{
        .errors = error{
            InputOutput,
            ShortWrite,
            InvalidDeviceRead,
            NoDevice,
            BrokenPipe,
            ConnectionResetByPeer,
            SocketUnconnected,
            EndOfStream,
            ReadFailed,
            Unseekable,
            Streaming,
            NotOpenForReading,
            NotOpenForWriting,
            WouldBlock,
            Timeout,
            OperationUnsupported,
            FileLocksUnsupported,
            FileSystem,
            UnrecognizedVolume,
            NonResizable,
        },
        .text = "I/O error",
        .show_name = true,
    },
    .{
        .errors = error{ OutOfMemory, SystemResources, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ResourceLimitReached, ConcurrencyUnavailable },
        .text = "out of system resources",
        .show_name = true,
    },
    .{
        .errors = error{ InvalidExe, InvalidBatchScriptArg, InvalidUserId, InvalidProcessGroupId, InvalidName, ProcessAlreadyExec, StreamTooLong },
        .text = "a helper command (`bzip2` or `diskutil`) could not run",
        .show_name = true,
    },
    .{ .errors = error{Canceled}, .text = "canceled" },
    .{
        // Failures of the engine's own invariants: bugs, not bad input.
        .errors = error{ InvalidFlashPlan, RangeOutsideImage, InvalidBlockSize, BackwardStreamRequest, ScratchBufferTooSmall, InternalBufferTooSmall, ObserverFailed, Overflow, DivisionByZero, Unexpected },
        .text = "internal error",
        .show_name = true,
    },
};

/// Errors in `error_texts` that only some platforms' backends return. Any
/// other entry must be a member of `CommandError`, so stale or misspelled
/// entries fail the build too.
const platform_specific_errors = error{
    // macOS disk discovery, which runs `diskutil`.
    UnknownDiskId,
    AmbiguousDiskId,
    DiskListFailed,
    UnmountFailed,
    Timeout,
    ConcurrencyUnavailable,
    StreamTooLong,
    // Raw-device I/O in the POSIX backend.
    ShortWrite,
    InvalidDeviceRead,
    ScratchBufferTooSmall,
};

comptime {
    @setEvalBranchQuota(200_000);
    var seen: []const []const u8 = &.{};
    var stale: []const u8 = "";
    for (error_texts) |entry| {
        for (errorNames(entry.errors)) |name| {
            for (seen) |other| if (std.mem.eql(u8, name, other)) @compileError("error." ++ name ++ " appears twice in error_texts");
            seen = seen ++ .{name};
            if (!hasError(CommandError, name) and !hasError(platform_specific_errors, name)) stale = stale ++ " " ++ name;
        }
    }
    if (stale.len != 0) @compileError("error_texts describes errors no command returns on this target; remove them or list them in platform_specific_errors:" ++ stale);

    var missing: []const u8 = "";
    for (errorNames(CommandError)) |name| {
        for (seen) |other| {
            if (std.mem.eql(u8, name, other)) break;
        } else missing = missing ++ " " ++ name;
    }
    if (missing.len != 0) @compileError("no message in error_texts for:" ++ missing);
}

fn errorNames(comptime Set: type) []const [:0]const u8 {
    return @typeInfo(Set).error_set.error_names.?;
}

fn hasError(comptime Set: type, comptime name: []const u8) bool {
    for (errorNames(Set)) |member| if (std.mem.eql(u8, member, name)) return true;
    return false;
}

fn errorText(comptime name: []const u8) ErrorText {
    @setEvalBranchQuota(100_000);
    for (error_texts) |entry| if (hasError(entry.errors, name)) return entry;
    @compileError("no message for error." ++ name ++ "; add it to error_texts in main.zig");
}

fn writeUserError(writer: *std.Io.Writer, err: CommandError) !void {
    switch (err) {
        inline else => |known| {
            const entry = comptime errorText(@errorName(known));
            if (entry.show_name) {
                try writer.print("{s}: {t}\n", .{ entry.text, known });
            } else {
                try writer.print("{s}\n", .{entry.text});
            }
        },
    }
}

fn bytesPerSecond(bytes: u64, elapsed_ns: u64) u64 {
    return @intCast((@as(u128, bytes) * std.time.ns_per_s) / elapsed_ns);
}

fn formatBytes(buffer: []u8, value: u64) ![]const u8 {
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

test "writeUserError prints specific and grouped messages" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeUserError(&writer, error.DestinationTooSmall);
    try writeUserError(&writer, error.InvalidExt4Superblock);
    try std.testing.expectEqualStrings(
        "the target is smaller than the image\n" ++
            "the image is corrupt or truncated: InvalidExt4Superblock\n",
        writer.buffered(),
    );
}
