//! What the interface knows about images, drives and flashing, and the
//! services it asks to do the work.
//!
//! Everything here is plain data, so `update` functions can be tested
//! without a window, a disk or the flashing library: tests pass their own
//! `Services` and `Icons`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;

/// A place an image can be written to: a whole disk, or in debug builds a
/// regular file.
pub const Drive = struct {
    /// What the flash is given as its target: `/dev/disk4`, or a file.
    path: []const u8,
    /// What the drive calls itself, such as `SanDisk Ultra`.
    name: []const u8,
    /// Where it is: the device path and any mount points.
    location: []const u8,
    size: u64,
    /// Internal or OS-installable, which the library refuses to write to
    /// without being forced. Hidden from the list unless asked for.
    system: bool,
    removable: bool,
    /// A regular file rather than a device. Writing one needs no
    /// confirmation.
    file: bool = false,

    pub fn clone(self: Drive, gpa: Allocator) Allocator.Error!Drive {
        const path = try gpa.dupe(u8, self.path);
        errdefer gpa.free(path);
        const name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(name);
        const location = try gpa.dupe(u8, self.location);

        var copy = self;
        copy.path = path;
        copy.name = name;
        copy.location = location;
        return copy;
    }

    pub fn deinit(self: Drive, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.name);
        gpa.free(self.location);
    }
};

/// Drives owned with the gpa.
pub const DriveList = struct {
    items: []Drive,

    pub fn deinit(self: DriveList, gpa: Allocator) void {
        for (self.items) |drive| drive.deinit(gpa);
        gpa.free(self.items);
    }
};

/// The result of `Services.listDrives`.
pub const DriveListing = union(enum) {
    listed: DriveList,
    failed: anyerror,

    pub fn deinit(self: DriveListing, gpa: Allocator) void {
        switch (self) {
            .listed => |list| list.deinit(gpa),
            .failed => {},
        }
    }
};

/// What probing an image found. Strings are static.
pub const ImageDetails = struct {
    /// Decoded size: what will be written at most.
    size: u64,
    /// Size of the file as stored.
    file_size: u64,
    /// The compression's name, or null for a raw image.
    compression: ?[]const u8 = null,
    /// The recognized layout, such as `mbr`.
    layout: []const u8,
};

/// How far loading has got: compressed images are decoded once, up front.
pub const Loading = struct {
    /// Compressed bytes decoded so far.
    decoded: u64 = 0,
    /// The compressed size; zero while unknown or for raw images.
    total: u64 = 0,
};

/// Progress of the load with `id`.
pub const ImageProgress = struct {
    id: u32,
    loading: Loading,
};

pub const ImageHandlers = struct {
    progress: app.Handler(ImageProgress),
    loaded: app.Handler(ImageLoad),
};

/// The result of `Services.loadImage`, for the load with `id`.
pub const ImageLoad = struct {
    id: u32,
    result: union(enum) {
        ready: ImageDetails,
        failed: anyerror,
    },
};

/// The image the user chose.
pub const Image = struct {
    /// Tells this load's result from those of images chosen before.
    id: u32,
    /// Owned with the gpa.
    path: []u8,
    status: Status = .{ .loading = .{} },

    pub const Status = union(enum) {
        loading: Loading,
        ready: ImageDetails,
        failed: anyerror,
    };

    pub fn name(self: Image) []const u8 {
        return std.fs.path.basename(self.path);
    }

    /// The decoded size, once known.
    pub fn size(self: Image) ?u64 {
        return switch (self.status) {
            .ready => |details| details.size,
            else => null,
        };
    }
};

pub const FlashPhase = enum {
    /// Checking and unmounting the target.
    starting,
    /// Decoding a compressed image into its spool.
    decoding,
    flashing,
    /// Reading the target back.
    verifying,
};

/// A progress sample, posted while a flash runs.
pub const FlashProgress = struct {
    phase: FlashPhase,
    completed: u64,
    /// Zero while unknown.
    total: u64,
    /// When the sample was taken, on a monotonic clock.
    at_ns: u64,
};

/// A flash in progress, as the interface shows it.
pub const Running = struct {
    phase: FlashPhase = .starting,
    completed: u64 = 0,
    total: u64 = 0,
    /// Smoothed bytes per second within the current phase; zero until
    /// measured.
    speed: f64 = 0,
    /// The sample `speed` was last measured from.
    sample_ns: u64 = 0,
    sample_completed: u64 = 0,
    /// Set once the user asked to stop.
    canceling: bool = false,

    /// The interval speed is measured over, so that it doesn't jitter
    /// with every sample.
    const speed_window_ns = 500 * std.time.ns_per_ms;

    /// Takes in a progress sample.
    pub fn advance(self: *Running, sample: FlashProgress) void {
        if (sample.phase != self.phase) {
            // a new phase restarts the count and its speed
            self.* = .{ .phase = sample.phase, .canceling = self.canceling };
            self.sample_ns = sample.at_ns;
            self.sample_completed = sample.completed;
        } else if (self.sample_ns == 0) {
            self.sample_ns = sample.at_ns;
            self.sample_completed = sample.completed;
        } else if (sample.at_ns >= self.sample_ns + speed_window_ns and sample.completed >= self.sample_completed) {
            const seconds = @as(f64, @floatFromInt(sample.at_ns - self.sample_ns)) / std.time.ns_per_s;
            const measured = @as(f64, @floatFromInt(sample.completed - self.sample_completed)) / seconds;
            self.speed = if (self.speed == 0) measured else 0.6 * self.speed + 0.4 * measured;
            self.sample_ns = sample.at_ns;
            self.sample_completed = sample.completed;
        }
        self.completed = sample.completed;
        self.total = sample.total;
    }

    /// Completion of the current phase from 0 to 1, if its total is known.
    pub fn fraction(self: Running) ?f32 {
        if (self.total == 0) return null;
        const value = @as(f64, @floatFromInt(self.completed)) / @as(f64, @floatFromInt(self.total));
        return @floatCast(std.math.clamp(value, 0, 1));
    }

    /// Seconds left in the current phase at the current speed.
    pub fn secondsLeft(self: Running) ?f64 {
        if (self.speed <= 0 or self.total == 0 or self.completed > self.total) return null;
        return @as(f64, @floatFromInt(self.total - self.completed)) / self.speed;
    }
};

pub const FlashSummary = struct {
    image_size: u64,
    bytes_written: u64,
    elapsed_ns: u64,
};

/// How a flash ended.
pub const FlashOutcome = union(enum) {
    done: FlashSummary,
    failed: anyerror,
    canceled,
};

pub const FlashHandlers = struct {
    progress: app.Handler(FlashProgress),
    done: app.Handler(FlashOutcome),
};

/// Side effects the interface asks for. Each request returns at once; the
/// answer arrives later as a message through the handler it was given, so
/// `update` never blocks or re-enters the runtime.
pub const Services = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Lets the user choose an image file. Posts the path, owned by the
        /// message, or null if the user canceled.
        pickImage: *const fn (ctx: *anyopaque, on_picked: app.Handler(?[]u8)) void,
        /// Opens and probes the image at `path` in the background,
        /// replacing any image loaded before. `path` is only borrowed for
        /// the call.
        loadImage: *const fn (ctx: *anyopaque, id: u32, path: []const u8, handlers: ImageHandlers) void,
        /// Forgets the loaded image.
        unloadImage: *const fn (ctx: *anyopaque) void,
        /// Lists every drive, system ones included, in the background.
        listDrives: *const fn (ctx: *anyopaque, on_listed: app.Handler(DriveListing)) void,
        /// Writes the loaded image with `image_id` to `target` in the
        /// background. `target` is only borrowed for the call.
        startFlash: *const fn (ctx: *anyopaque, image_id: u32, target: *const Drive, handlers: FlashHandlers) void,
        /// Asks the running flash to stop. It still reports how it ended.
        cancelFlash: *const fn (ctx: *anyopaque) void,
    };

    pub fn pickImage(self: Services, on_picked: app.Handler(?[]u8)) void {
        self.vtable.pickImage(self.ctx, on_picked);
    }

    pub fn loadImage(self: Services, id: u32, path: []const u8, handlers: ImageHandlers) void {
        self.vtable.loadImage(self.ctx, id, path, handlers);
    }

    pub fn unloadImage(self: Services) void {
        self.vtable.unloadImage(self.ctx);
    }

    pub fn listDrives(self: Services, on_listed: app.Handler(DriveListing)) void {
        self.vtable.listDrives(self.ctx, on_listed);
    }

    pub fn startFlash(self: Services, image_id: u32, target: *const Drive, handlers: FlashHandlers) void {
        self.vtable.startFlash(self.ctx, image_id, target, handlers);
    }

    pub fn cancelFlash(self: Services) void {
        self.vtable.cancelFlash(self.ctx);
    }
};

pub const Icon = enum { image, drive, flash, done, failed, warning };

/// Makes icon content for views, which the renderer draws. Content is
/// allocated in the frame arena.
pub const Icons = struct {
    ctx: *anyopaque,
    make: *const fn (ctx: *anyopaque, arena: Allocator, icon: Icon, color: fabrum.Color) Allocator.Error!*layout.Content,

    pub fn content(self: Icons, arena: Allocator, icon: Icon, color: fabrum.Color) Allocator.Error!*layout.Content {
        return self.make(self.ctx, arena, icon, color);
    }
};

/// What to tell the user about an error from the library or the platform.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "Permission denied. Writing to a drive needs administrator rights.",
        error.FileNotFound => "The file could not be found.",
        error.DestinationTooSmall => "The target is too small for this image.",
        error.VerificationFailed => "Validation failed: the target does not read back what was written.",
        error.UnmountFailed => "The drive could not be unmounted. Close anything using it and try again.",
        error.UnsupportedPartitionFilesystem => "The image has a partition this version can't plan a write for.",
        error.UnsupportedCompression => "The image uses an unsupported compression format.",
        error.InvalidCompressedImage => "The compressed image is corrupt or truncated.",
        error.Bzip2Unavailable => "bzip2 images need the bzip2 command, which was not found.",
        error.SpoolDirectoryFull => "Not enough space to decompress the image.",
        error.UnsupportedImageSource, error.IsDir => "The image must be a regular file.",
        error.UnsupportedTargetType => "The target can't be written to.",
        error.DiskListFailed => "Listing drives failed.",
        error.ReadOnlyFileSystem => "The target is read-only.",
        error.DeviceBusy, error.FileBusy => "The drive is in use.",
        error.InputOutput => "An I/O error occurred.",
        error.OutOfMemory => "Out of memory.",
        error.DeviceWritesDisabled => "Writing to drives is disabled while OPENETCHER_GUI_FILE_TARGETS is set.",
        error.ImageNotLoaded => "The image is no longer loaded. Choose it again.",
        error.InvalidImage,
        error.InvalidIso9660Image,
        error.InvalidPartitionTable,
        error.InvalidExt4Superblock,
        error.ImageTruncated,
        error.UnexpectedEndOfImage,
        => "This doesn't look like a supported disk image (ISO 9660, MBR or ext4).",
        else => @errorName(err),
    };
}

test describeError {
    try std.testing.expectEqualStrings("The target is too small for this image.", describeError(error.DestinationTooSmall));
    try std.testing.expectEqualStrings("SomethingElse", describeError(error.SomethingElse));
}

test "Drive.clone owns its strings" {
    const gpa = std.testing.allocator;
    var path = "/dev/disk4".*;
    const drive: Drive = .{ .path = &path, .name = "Ultra", .location = "/dev/disk4", .size = 32, .system = false, .removable = true };
    const copy = try drive.clone(gpa);
    defer copy.deinit(gpa);
    path[5] = 'X';
    try std.testing.expectEqualStrings("/dev/disk4", copy.path);
}

test "Running measures speed over a window and restarts it each phase" {
    var running: Running = .{};
    const ms = std.time.ns_per_ms;
    running.advance(.{ .phase = .flashing, .completed = 0, .total = 4000, .at_ns = 1000 * ms });
    running.advance(.{ .phase = .flashing, .completed = 100, .total = 4000, .at_ns = 1100 * ms });
    // too soon to measure
    try std.testing.expectEqual(0, running.speed);
    try std.testing.expectEqual(null, running.secondsLeft());

    running.advance(.{ .phase = .flashing, .completed = 1000, .total = 4000, .at_ns = 1500 * ms });
    try std.testing.expectApproxEqAbs(2000, running.speed, 1e-6);
    try std.testing.expectApproxEqAbs(1.5, running.secondsLeft().?, 1e-6);
    try std.testing.expectApproxEqAbs(0.25, running.fraction().?, 1e-6);

    // smoothed with the next measurement
    running.advance(.{ .phase = .flashing, .completed = 3000, .total = 4000, .at_ns = 2000 * ms });
    try std.testing.expectApproxEqAbs(0.6 * 2000 + 0.4 * 4000, running.speed, 1e-6);

    running.canceling = true;
    running.advance(.{ .phase = .verifying, .completed = 0, .total = 4000, .at_ns = 2100 * ms });
    try std.testing.expectEqual(FlashPhase.verifying, running.phase);
    try std.testing.expectEqual(0, running.speed);
    try std.testing.expect(running.canceling);
}
