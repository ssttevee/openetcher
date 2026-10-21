//! Flash sessions have their own service lifecycle. Image loading and
//! drive listing are runtime tasks in tasks.zig; the source cache is
//! shared so a later flash can reuse an already decoded image.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openetcher = @import("openetcher");
const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("ui.zig").model;
const progress = @import("progress.zig");
const work_tasks = @import("tasks.zig");

const Services = @This();

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
options: Options,
monitor: progress.Monitor = undefined,
/// Waiting for flash cancellation happens off the UI thread.
tasks: Io.Group = .init,
/// The flash, kept apart so that canceling it leaves the other tasks be.
flash_group: Io.Group = .init,

work: work_tasks.Work = undefined,
/// Guards the flash watcher, which background tasks share.
mutex: Io.Mutex = .init,
flash_watch: ?FlashWatch = null,

const FlashWatch = struct {
    handlers: model.FlashHandlers,
    last: ?model.FlashProgress = null,
};

/// The `std.Progress` node a flash reports under.
const flash_task = "openetcher-gui flash";

/// Starts the progress monitor. `self` must not move afterwards.
pub fn start(self: *Services) !void {
    self.work = .{ .gpa = self.gpa, .options = self.options };
    try self.monitor.start(self.io, self, onProgress);
    self.work.root = self.monitor.root;
}

/// Cancels whatever still runs, waiting for a flash to leave its target
/// synced, and frees everything.
pub fn shutdown(self: *Services) void {
    self.flash_group.cancel(self.io);
    self.tasks.cancel(self.io);
    self.work.clear(self.io);
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
    self.work.mutex.lockUncancelable(self.io);
    const loaded = if (self.work.loaded) |loaded| if (loaded.id == image_id) loaded else null else null;
    self.work.mutex.unlock(self.io);
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

    self.work.mutex.lockUncancelable(self.io);
    if (self.work.load_watch) |*watch| {
        var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
        if (tree.findUnder(work_tasks.loadTaskName(&name_buffer, watch.id), "compressed KiB decoded")) |node| {
            const loading: model.Loading = .{ .decoded = bytes(node.completed), .total = bytes(node.total) };
            if (!std.meta.eql(loading, watch.last)) {
                watch.last = loading;
                watch.progress.post(.{ .id = watch.id, .loading = loading }) catch |err| std.log.err("dropped image progress: {t}", .{err});
            }
        }
    }
    self.work.mutex.unlock(self.io);

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
