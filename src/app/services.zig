//! The interface's `model.Services`, done with the openetcher library on
//! background tasks. Results and progress come back to the runtime as
//! posted messages.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openetcher = @import("openetcher");
const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("ui.zig").model;
const progress = @import("progress.zig");

const Services = @This();

/// Shows a file picker; the platform shell implements it.
pub const Picker = struct {
    ctx: ?*anyopaque = null,
    choose: *const fn (ctx: ?*anyopaque, extensions: []const [*:0]const u8, services: *Services) void,
};

/// File types offered by the picker: raw and ISO images, plain or
/// compressed with a codec the library decodes. Detection itself is by
/// content, so this only narrows the list.
pub const image_extensions = [_][*:0]const u8{ "img", "iso", "raw", "bin", "gz", "xz", "zst", "bz2" };

pub const Options = struct {
    /// Where compressed images are decoded; null uses the library default.
    spool_dir: ?[]const u8 = null,
    /// Regular files offered as targets, for development and tests.
    file_targets: []const []const u8 = &.{},
    /// Refuse to write anything but `file_targets`, for development.
    file_targets_only: bool = false,
};

gpa: Allocator,
io: Io,
poster: app.Poster,
picker: Picker,
options: Options,
monitor: progress.Monitor = undefined,
/// Loading and listing, which may still run at exit.
tasks: Io.Group = .init,
/// The flash, kept apart so that canceling it leaves the other tasks be.
flash_group: Io.Group = .init,

/// Main thread only.
pick_handler: ?app.Handler(?[]u8) = null,

/// Guards everything below, which background tasks share.
mutex: Io.Mutex = .init,
/// The id of the image the interface wants; results for others are dropped.
wanted_image: u32 = 0,
loaded: ?*Loaded = null,
load_watch: ?LoadWatch = null,
flash_watch: ?FlashWatch = null,

const Loaded = struct {
    id: u32,
    source: openetcher.ImageSource,
};

const LoadWatch = struct {
    id: u32,
    handlers: model.ImageHandlers,
    last: model.Loading = .{},
};

const FlashWatch = struct {
    handlers: model.FlashHandlers,
    last: ?model.FlashProgress = null,
};

/// The `std.Progress` node a flash reports under.
const flash_task = "openetcher-gui flash";

/// Starts the progress monitor. `self` must not move afterwards.
pub fn start(self: *Services) !void {
    try self.monitor.start(self.io, self, onProgress);
}

/// Cancels whatever still runs, waiting for a flash to leave its target
/// synced, and frees everything.
pub fn shutdown(self: *Services) void {
    self.flash_group.cancel(self.io);
    self.tasks.cancel(self.io);
    self.unload();
    self.monitor.stop();
}

/// Whether a flash is running, for confirming before quitting.
pub fn flashing(self: *Services) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.flash_watch != null;
}

pub fn interface(self: *Services) model.Services {
    return .{ .ctx = self, .vtable = &.{
        .pickImage = pickImage,
        .loadImage = loadImage,
        .unloadImage = unloadImage,
        .listDrives = listDrives,
        .startFlash = startFlash,
        .cancelFlash = cancelFlash,
    } };
}

fn get(ctx: *anyopaque) *Services {
    return @ptrCast(@alignCast(ctx));
}

/// Posts a message, or drops it if that fails: the runtime frees the
/// payload either way, and a lost message only leaves the screen waiting.
fn post(self: *Services, handler: anytype, payload: anytype) void {
    self.poster.post(handler, payload) catch |err| std.log.err("dropped a message: {t}", .{err});
}

fn lock(self: *Services) void {
    self.mutex.lockUncancelable(self.io);
}

fn unlock(self: *Services) void {
    self.mutex.unlock(self.io);
}

// Picking

fn pickImage(ctx: *anyopaque, on_picked: app.Handler(?[]u8)) void {
    const self = get(ctx);
    self.pick_handler = on_picked;
    self.picker.choose(self.picker.ctx, &image_extensions, self);
}

/// Called by the picker on the main thread with the chosen path, or null.
pub fn picked(self: *Services, path: ?[]const u8) void {
    const handler = self.pick_handler orelse return;
    self.pick_handler = null;
    const owned: ?[]u8 = if (path) |p| self.gpa.dupe(u8, p) catch null else null;
    self.post(handler, owned);
}

// Loading

fn loadImage(ctx: *anyopaque, id: u32, path: []const u8, handlers: model.ImageHandlers) void {
    const self = get(ctx);
    const owned = self.gpa.dupe(u8, path) catch |err| return self.post(handlers.loaded, model.ImageLoad{ .id = id, .result = .{ .failed = err } });

    self.lock();
    self.wanted_image = id;
    self.load_watch = .{ .id = id, .handlers = handlers };
    self.unlock();

    self.tasks.concurrent(self.io, loadTask, .{ self, id, owned, handlers }) catch |err| {
        self.gpa.free(owned);
        self.post(handlers.loaded, model.ImageLoad{ .id = id, .result = .{ .failed = err } });
    };
}

fn loadTask(self: *Services, id: u32, path: []u8, handlers: model.ImageHandlers) void {
    defer self.gpa.free(path);

    var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const node = self.monitor.root.start(loadTaskName(&name_buffer, id), 0);
    defer node.end();

    const loaded = self.gpa.create(Loaded) catch |err| return self.post(handlers.loaded, model.ImageLoad{ .id = id, .result = .{ .failed = err } });
    const details = self.open(loaded, path, node) catch |err| {
        self.gpa.destroy(loaded);
        if (err == error.Canceled) return;
        self.finishLoad(id);
        return self.post(handlers.loaded, model.ImageLoad{ .id = id, .result = .{ .failed = err } });
    };
    loaded.id = id;

    self.lock();
    const wanted = self.wanted_image == id;
    const replaced = if (wanted) self.loaded else loaded;
    if (wanted) self.loaded = loaded;
    if (self.load_watch) |watch| if (watch.id == id) {
        self.load_watch = null;
    };
    self.unlock();
    if (replaced) |old| self.free(old);

    self.post(handlers.loaded, model.ImageLoad{ .id = id, .result = .{ .ready = details } });
}

fn finishLoad(self: *Services, id: u32) void {
    self.lock();
    defer self.unlock();
    if (self.load_watch) |watch| if (watch.id == id) {
        self.load_watch = null;
    };
}

fn loadTaskName(buffer: []u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "openetcher-gui load {d}", .{id}) catch unreachable;
}

/// Opens and probes the image, decoding a compressed one into its spool.
fn open(self: *Services, loaded: *Loaded, path: []const u8, node: std.Progress.Node) !model.ImageDetails {
    loaded.source = try openetcher.openImageSourceFromPath(self.gpa, self.io, path, .{ .spool_dir = self.options.spool_dir, .progress = node });
    errdefer loaded.source.deinit();
    const info = try openetcher.probeImageSource(self.gpa, self.io, &loaded.source, .{});
    defer info.deinit(self.gpa);
    // the node ends with this task; a later spool reports under the flash
    loaded.source.progress = .none;

    return .{
        .size = info.image_size,
        .file_size = info.encoded_size orelse info.image_size,
        .compression = if (info.compression == .none) null else @tagName(info.compression),
        .layout = @tagName(info.layout),
    };
}

fn free(self: *Services, loaded: *Loaded) void {
    loaded.source.deinit();
    self.gpa.destroy(loaded);
}

fn unloadImage(ctx: *anyopaque) void {
    get(ctx).unload();
}

fn unload(self: *Services) void {
    self.lock();
    self.wanted_image = 0;
    self.load_watch = null;
    const loaded = self.loaded;
    self.loaded = null;
    self.unlock();
    if (loaded) |old| self.free(old);
}

// Drives

fn listDrives(ctx: *anyopaque, on_listed: app.Handler(model.DriveListing)) void {
    const self = get(ctx);
    self.tasks.concurrent(self.io, listTask, .{ self, on_listed }) catch |err| self.post(on_listed, model.DriveListing{ .failed = err });
}

fn listTask(self: *Services, on_listed: app.Handler(model.DriveListing)) void {
    const listing: model.DriveListing = if (self.list()) |drives| .{ .listed = drives } else |err| switch (err) {
        error.Canceled => return,
        else => .{ .failed = err },
    };
    self.post(on_listed, listing);
}

fn list(self: *Services) !model.DriveList {
    var drives: std.ArrayList(model.Drive) = .empty;
    errdefer {
        for (drives.items) |drive| drive.deinit(self.gpa);
        drives.deinit(self.gpa);
    }

    // `diskutil` only reads; nothing here touches a disk's contents
    const disks = try openetcher.device_api.listCandidateDisks(self.gpa, self.io, .{ .include_system = true });
    defer disks.deinit(self.gpa);
    for (disks.items) |disk| {
        var location: std.Io.Writer.Allocating = .init(self.gpa);
        defer location.deinit();
        try location.writer.writeAll(disk.device_path);
        for (disk.mount_points) |mount_point| try location.writer.print(", {s}", .{mount_point.path});

        const drive: model.Drive = .{
            .path = disk.device_path,
            .name = if (disk.description.len > 0) disk.description else disk.display_name,
            .location = location.written(),
            .size = disk.size,
            .system = disk.system or disk.protected,
            .removable = disk.removable,
        };
        try drives.ensureUnusedCapacity(self.gpa, 1);
        drives.appendAssumeCapacity(try drive.clone(self.gpa));
    }

    for (self.options.file_targets) |path| {
        const stat = Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
        if (stat.kind != .file) continue;
        const drive: model.Drive = .{
            .path = path,
            .name = std.fs.path.basename(path),
            .location = path,
            .size = stat.size,
            .system = false,
            .removable = false,
            .file = true,
        };
        try drives.ensureUnusedCapacity(self.gpa, 1);
        drives.appendAssumeCapacity(try drive.clone(self.gpa));
    }

    return .{ .items = try drives.toOwnedSlice(self.gpa) };
}

// Flashing

fn startFlash(ctx: *anyopaque, image_id: u32, target: *const model.Drive, handlers: model.FlashHandlers) void {
    const self = get(ctx);
    if (self.options.file_targets_only and !target.file) {
        return self.post(handlers.done, model.FlashOutcome{ .failed = error.DeviceWritesDisabled });
    }
    const path = self.gpa.dupe(u8, target.path) catch |err| return self.post(handlers.done, model.FlashOutcome{ .failed = err });

    self.lock();
    self.flash_watch = .{ .handlers = handlers };
    self.unlock();

    self.flash_group.concurrent(self.io, flashTask, .{ self, image_id, path, handlers }) catch |err| {
        self.gpa.free(path);
        self.endFlash();
        self.post(handlers.done, model.FlashOutcome{ .failed = err });
    };
}

fn endFlash(self: *Services) void {
    self.lock();
    defer self.unlock();
    self.flash_watch = null;
}

fn flashTask(self: *Services, image_id: u32, path: []u8, handlers: model.FlashHandlers) void {
    defer self.gpa.free(path);
    const node = self.monitor.root.start(flash_task, 0);
    defer node.end();
    const started = Io.Clock.awake.now(self.io);

    const outcome: model.FlashOutcome = if (self.flash(image_id, path, node)) |report| .{ .done = .{
        .image_size = report.image_size,
        .bytes_written = report.bytes_written,
        .elapsed_ns = @intCast(@max(0, started.durationTo(Io.Clock.awake.now(self.io)).nanoseconds)),
    } } else |err| switch (err) {
        error.Canceled => .canceled,
        else => .{ .failed = err },
    };

    // no progress may follow the outcome
    self.endFlash();
    self.post(handlers.done, outcome);
}

fn flash(self: *Services, image_id: u32, path: []const u8, node: std.Progress.Node) !openetcher.FlashReport {
    self.lock();
    const loaded = if (self.loaded) |loaded| if (loaded.id == image_id) loaded else null else null;
    self.unlock();
    // the interface can't remove or replace the image while it flashes
    const source = &(loaded orelse return error.ImageNotLoaded).source;

    source.progress = node;
    defer source.progress = .none;
    return openetcher.flashSource(self.gpa, self.io, source, path, .{ .progress = node });
}

fn cancelFlash(ctx: *anyopaque) void {
    const self = get(ctx);
    // canceling waits for the flash to wind down, which is not for the main thread
    self.tasks.concurrent(self.io, cancelTask, .{self}) catch self.flash_group.cancel(self.io);
}

fn cancelTask(self: *Services) void {
    self.flash_group.cancel(self.io);
}

// Progress

/// Turns each progress packet into messages for whoever is watching.
fn onProgress(ctx: *anyopaque, tree: progress.Tree) void {
    const self = get(ctx);
    self.lock();
    defer self.unlock();

    if (self.load_watch) |*watch| {
        var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        if (tree.findUnder(loadTaskName(&name_buffer, watch.id), "compressed KiB decoded")) |node| {
            const loading: model.Loading = .{ .decoded = bytes(node.completed), .total = bytes(node.total) };
            if (!std.meta.eql(loading, watch.last)) {
                watch.last = loading;
                self.post(watch.handlers.progress, model.ImageProgress{ .id = watch.id, .loading = loading });
            }
        }
    }

    if (self.flash_watch) |*watch| {
        const phase: model.FlashPhase, const node: ?progress.Node = if (tree.findUnder(flash_task, "KiB verified")) |node|
            .{ .verifying, node }
        else if (tree.findUnder(flash_task, "KiB written")) |node|
            .{ .flashing, node }
        else if (tree.findUnder(flash_task, "compressed KiB decoded")) |node|
            .{ .decoding, node }
        else
            .{ .starting, null };

        const sample: model.FlashProgress = .{
            .phase = phase,
            .completed = if (node) |n| bytes(n.completed) else 0,
            .total = if (node) |n| bytes(n.total) else 0,
            .at_ns = @intCast(@max(0, Io.Clock.awake.now(self.io).nanoseconds)),
        };
        const changed = if (watch.last) |last|
            last.phase != sample.phase or last.completed != sample.completed or last.total != sample.total
        else
            true;
        if (changed) {
            watch.last = sample;
            self.post(watch.handlers.progress, sample);
        }
    }
}

fn bytes(units: u32) u64 {
    return @as(u64, units) * progress.unit_bytes;
}

comptime {
    // the library counts progress in the same unit
    std.debug.assert(openetcher.progress_unit_bytes == progress.unit_bytes);
}

test {
    _ = progress;
}
