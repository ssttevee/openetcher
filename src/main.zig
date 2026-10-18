const std = @import("std");

const openetcher = @import("openetcher");

const cli_args = @import("cli/args.zig");
const output = @import("cli/output.zig");
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const command = cli_args.parseCommand(Command, argv[1..]) catch {
        try writeUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    const context: Context = .{ .arena = arena, .io = io, .stdout = stdout, .stderr = stderr, .environ = init.environ_map };
    const result = switch (command) {
        .info => |args| info(context, args),
        .plan => |args| plan(context, args),
        .disks => |args| disks(context, args),
        .flash => |args| flash(context, args),
    };
    result catch |err| switch (err) {
        // With the terminal gone there is no one to tell.
        error.WriteFailed => return err,
        else => |command_error| {
            try writeUserError(stderr, command_error);
            try stderr.flush();
            std.process.exit(1);
        },
    };
    try stdout.flush();
}

const Command = union(enum) {
    info: ImageArgs,
    plan: ImageArgs,
    disks: DisksArgs,
    flash: FlashArgs,
};

/// Arguments of `info` and `plan`. See `cli/args.zig` for how fields map to
/// the command line.
const ImageArgs = struct {
    humanize: bool = false,
    json: bool = false,
    spool_dir: ?[]const u8 = null,
    image: []const u8,

    pub const positionals: []const []const u8 = &.{"image"};
    pub const flag_names = .{ .humanize = "-h" };
};

const DisksArgs = struct {
    humanize: bool = false,
    json: bool = false,
    /// Include system and virtual disks.
    all: bool = false,

    pub const flag_names = .{ .humanize = "-h" };
};

const FlashArgs = struct {
    humanize: bool = false,
    force: bool = false,
    spool_dir: ?[]const u8 = null,
    disk_id: ?[]const u8 = null,
    image: []const u8,
    device: ?[]const u8 = null,

    pub const positionals: []const []const u8 = &.{ "image", "device" };
    pub const flag_names = .{ .humanize = "-h" };

    /// The target is a device path or a disk id, never both.
    pub fn validate(self: FlashArgs) bool {
        return (self.device == null) != (self.disk_id == null);
    }
};

const usage =
    \\usage:
    \\  openetcher info [-h] [--json] [--spool-dir <dir>] <image>
    \\  openetcher plan [-h] [--json] [--spool-dir <dir>] <image>
    \\  openetcher disks [-h] [--json] [--all]
    \\  openetcher flash [-h] [--force] [--spool-dir <dir>] <image> <device>
    \\  openetcher flash [-h] [--force] [--spool-dir <dir>] <image> --disk-id <id>
    \\
    \\compressed images are decoded once into --spool-dir (default: $TMPDIR)
    \\
;

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(usage);
}

/// What every command needs from `main`.
const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ: *const std.process.Environ.Map,

    fn sourceOptions(self: Context, spool_dir: ?[]const u8, progress: std.Progress.Node) openetcher.SourceOptions {
        return .{ .spool_dir = spool_dir orelse defaultSpoolDir(self.environ), .progress = progress };
    }
};

/// What a command can fail with: a library error for `writeUserError`, or
/// a failed write to the terminal.
const RunError = CommandError || std.Io.Writer.Error;

fn info(context: Context, args: ImageArgs) RunError!void {
    var image_source, const image_info = probe: {
        // Probing spools compressed images, which can take minutes.
        const progress = startProgress(context.io);
        errdefer progress.end();
        var image_source = try openetcher.openImageSourceFromPath(context.arena, context.io, args.image, context.sourceOptions(args.spool_dir, progress));
        errdefer image_source.deinit();
        const image_info = try openetcher.probeImageSource(context.arena, context.io, &image_source, .{});
        progress.end();
        break :probe .{ image_source, image_info };
    };
    defer image_source.deinit();
    defer image_info.deinit(context.arena);

    const info_view = try output.view(output.InfoView, context.arena, image_info);
    if (args.json) {
        try output.writeJson(context.stdout, info_view);
    } else {
        try output.writeInfoText(context.stdout, info_view, args.humanize);
    }
}

fn plan(context: Context, args: ImageArgs) RunError!void {
    var image_source, const flash_plan = planned: {
        // Planning spools compressed images, which can take minutes.
        const progress = startProgress(context.io);
        errdefer progress.end();
        var image_source = try openetcher.openImageSourceFromPath(context.arena, context.io, args.image, context.sourceOptions(args.spool_dir, progress));
        errdefer image_source.deinit();
        const flash_plan = try openetcher.planImageFlashSource(context.arena, context.io, &image_source, .{});
        progress.end();
        break :planned .{ image_source, flash_plan };
    };
    defer image_source.deinit();
    defer flash_plan.deinit(context.arena);

    const plan_view = try output.PlanView.init(context.arena, flash_plan);
    if (args.json) {
        try output.writeJson(context.stdout, plan_view);
    } else {
        try output.writePlanText(context.stdout, plan_view, args.humanize);
    }
}

fn disks(context: Context, args: DisksArgs) RunError!void {
    const list = try openetcher.device_api.listCandidateDisks(context.arena, context.io, if (args.all) .everything else .{});
    defer list.deinit(context.arena);

    const disk_views = try output.view([]const output.DiskView, context.arena, list.items);
    if (args.json) {
        try output.writeJson(context.stdout, disk_views);
    } else {
        try output.writeDisksText(context.stdout, disk_views, args.all, args.humanize);
    }
}

fn flash(context: Context, args: FlashArgs) RunError!void {
    const arena = context.arena;
    const io = context.io;
    const stdout = context.stdout;
    const stderr = context.stderr;

    // A disk id resolves to its disk, whose path the rest of the command
    // uses, so it lives until the command returns.
    const chosen = if (args.disk_id) |disk_id| try openetcher.device_api.resolveDiskId(arena, io, disk_id, .everything) else null;
    defer if (chosen) |owned| owned.deinit(arena);
    // `FlashArgs.validate` requires a disk id or a device path.
    const target_path = if (chosen) |owned| owned.disk.device_path else args.device.?;

    if (!args.force) {
        const protected = if (chosen) |owned| owned.disk.protected else protected: {
            const candidate = try openetcher.device_api.lookupDiskByPath(arena, io, target_path, .everything) orelse break :protected false;
            defer candidate.deinit(arena);
            break :protected candidate.disk.protected;
        };
        if (protected) return error.ProtectedTargetRequiresForce;
    }

    const target_info = try openetcher.device_api.probeTarget(arena, io, target_path);
    defer target_info.deinit(arena);

    if (!std.mem.eql(u8, target_info.requested_path, target_info.resolved_path)) {
        try stderr.print("normalized target: {s} -> {s}\n", .{ target_info.requested_path, target_info.resolved_path });
        try stderr.flush();
    }

    try stderr.print("preparing target: {s}\n", .{target_info.resolved_path});
    try stderr.flush();
    try openetcher.device_api.prepareTargetPath(arena, io, target_path);

    const start_time = std.Io.Clock.awake.now(io);
    const report = report: {
        const progress = startProgress(io);
        // Ending the display erases it, so an error message starts clean.
        errdefer progress.end();
        var image_source = try openetcher.openImageSourceFromPath(arena, io, args.image, context.sourceOptions(args.spool_dir, progress));
        defer image_source.deinit();
        const report = try openetcher.flashSource(arena, io, &image_source, target_path, .{
            .prepare_target = false,
            .strategy = if (args.force) .force_full_streaming else .planned_sparse,
            .progress = progress,
        });
        progress.end();
        break :report report;
    };

    const elapsed = start_time.durationTo(std.Io.Clock.awake.now(io));
    const elapsed_ns: u64 = @intCast(@max(elapsed.nanoseconds, 1));
    const actual_bytes_per_second = bytesPerSecond(report.bytes_written, elapsed_ns);
    const effective_bytes_per_second = bytesPerSecond(report.image_size, elapsed_ns);

    const written = output.Bytes.of(report.bytes_written).fmt(args.humanize);
    const skipped = output.Bytes.of(report.bytes_skipped).fmt(args.humanize);
    // Humanized counts carry their unit; plain ones need it spelled out.
    const unit = if (args.humanize) "" else " bytes";
    try stdout.print("wrote {f}{s} across {} ranges, skipped {f}{s}\n", .{ written, unit, report.range_count, skipped, unit });
    try stdout.print("actual throughput: {f}/s\n", .{output.Bytes.of(actual_bytes_per_second).fmt(true)});
    try stdout.print("effective throughput: {f}/s\n", .{output.Bytes.of(effective_bytes_per_second).fmt(true)});
}

/// Starts the progress display on stderr. It draws only when stderr is a
/// terminal, and forwards to a parent process instead when `ZIG_PROGRESS`
/// is set. End the returned node before writing anything else to stderr,
/// since ending it erases the display.
fn startProgress(io: std.Io) std.Progress.Node {
    return std.Progress.start(io, .{});
}

/// Directory for decoded copies of compressed images, from the usual
/// temporary-directory variables. Null falls back to the library default.
fn defaultSpoolDir(environ: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |name| {
        if (environ.get(name)) |value| if (value.len != 0) return value;
    }
    return null;
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
    .{ .errors = error{UnalignedTargetOffset}, .text = "the image's write plan starts a range inside a sector of the target, which the device cannot write" },
    .{ .errors = error{VerificationFailed}, .text = "verification failed: the target does not read back what was written" },
    .{ .errors = error{DiskListFailed}, .text = "listing disks failed: the system's disk service did not respond" },
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
        .errors = error{ OutOfMemory, SystemResources, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ResourceLimitReached },
        .text = "out of system resources",
        .show_name = true,
    },
    .{
        .errors = error{ InvalidExe, InvalidBatchScriptArg, InvalidUserId, InvalidProcessGroupId, InvalidName, ProcessAlreadyExec },
        .text = "the `bzip2` command could not run",
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
    // Disk discovery and unmounting.
    UnknownDiskId,
    AmbiguousDiskId,
    DiskListFailed,
    UnmountFailed,
    // Raw-device I/O in the POSIX backend.
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

test {
    _ = cli_args;
    _ = output;
}

test "commands parse their documented arguments" {
    const parse = cli_args.parseCommand;
    const shown = try parse(Command, &.{ "info", "-h", "image.img", "--spool-dir", "/tmp", "--json" });
    try std.testing.expect(shown.info.humanize and shown.info.json);
    try std.testing.expectEqualStrings("image.img", shown.info.image);
    try std.testing.expectEqualStrings("/tmp", shown.info.spool_dir.?);

    try std.testing.expectEqualStrings("a.img", (try parse(Command, &.{ "plan", "a.img" })).plan.image);
    const listed = try parse(Command, &.{ "disks", "--all", "--json" });
    try std.testing.expect(listed.disks.all and listed.disks.json and !listed.disks.humanize);

    const by_path = try parse(Command, &.{ "flash", "--force", "a.img", "/dev/disk4" });
    try std.testing.expect(by_path.flash.force);
    try std.testing.expectEqualStrings("/dev/disk4", by_path.flash.device.?);
    const by_id = try parse(Command, &.{ "flash", "a.img", "--disk-id", "macos-0123" });
    try std.testing.expectEqualStrings("macos-0123", by_id.flash.disk_id.?);
    try std.testing.expectEqual(@as(?[]const u8, null), by_id.flash.device);
}

test "invalid command lines are rejected" {
    const bad = [_][]const []const u8{
        &.{},
        &.{"bogus"},
        &.{"info"},
        &.{ "info", "--json" },
        &.{ "info", "--json", "--json", "a.img" },
        &.{ "info", "a.img", "b.img" },
        &.{ "info", "--spool-dir" },
        &.{ "plan", "-h", "-h", "a.img" },
        &.{ "disks", "a.img" },
        &.{ "disks", "--all", "--all" },
        &.{ "disks", "--spool-dir", "/tmp" },
        &.{ "flash", "a.img" },
        &.{ "flash", "a.img", "/dev/disk4", "--disk-id", "macos-0123" },
        &.{ "flash", "a.img", "/dev/disk4", "/dev/disk5" },
        &.{ "flash", "a.img", "--disk-id" },
        &.{ "flash", "--json", "a.img", "/dev/disk4" },
    };
    for (bad) |argv| try std.testing.expectError(error.InvalidArguments, cli_args.parseCommand(Command, argv));
}

test "usage shows every command and flag the parser accepts" {
    inline for (comptime std.meta.fieldNames(Command), comptime std.meta.fieldTypes(Command)) |command, Args| {
        try std.testing.expect(std.mem.indexOf(u8, usage, "openetcher " ++ command ++ " ") != null);
        inline for (comptime std.meta.fieldNames(Args)) |field| {
            if (comptime cli_args.isPositional(Args, field)) continue;
            try std.testing.expect(std.mem.indexOf(u8, usage, " [" ++ comptime cli_args.flagName(Args, field)) != null or
                std.mem.indexOf(u8, usage, " " ++ comptime cli_args.flagName(Args, field) ++ " <") != null);
        }
    }
}
