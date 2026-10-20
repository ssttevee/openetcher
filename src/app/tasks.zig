//! Runtime task functions and the image source shared with flashing.
const std = @import("std");
const openetcher = @import("openetcher");
const app = @import("fabrum").app;
const model = @import("ui/model.zig");
const progress = @import("progress.zig");
const Io = std.Io;

/// Domain resources outlive individual tasks. The runtime owns loading;
/// this cache owns the image source subsequently used by the flash service.
pub const Work = struct {
    gpa: std.mem.Allocator,
    options: @import("services.zig").Options = .{},
    mutex: Io.Mutex = .init,
    loaded: ?*Loaded = null,
    load_watch: ?LoadWatch = null,
    root: std.Progress.Node = .none,

    pub const Loaded = struct { id: u32, source: openetcher.ImageSource };
    pub const LoadWatch = struct {
        id: u32,
        task: *app.Task,
        handler: app.Handler(model.ImageProgress),
        last: model.Loading = .{},
    };

    pub fn free(self: *Work, loaded: *Loaded) void {
        loaded.source.deinit();
        self.gpa.destroy(loaded);
    }

    pub fn clear(self: *Work, io: Io) void {
        self.mutex.lockUncancelable(io);
        const old = self.loaded;
        self.loaded = null;
        self.mutex.unlock(io);
        if (old) |loaded| self.free(loaded);
    }

    fn open(self: *Work, task: *app.Task, loaded: *Loaded, path: []const u8, node: std.Progress.Node) !model.ImageDetails {
        loaded.source = try openetcher.openImageSourceFromPath(self.gpa, task.io, path, .{ .spool_dir = self.options.spool_dir, .progress = node });
        errdefer loaded.source.deinit();
        const info = try openetcher.probeImageSource(self.gpa, task.io, &loaded.source, .{});
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
};

pub fn loadImage(task: *app.Task, work: *Work, id: u32, path: []const u8, on_progress: app.Handler(model.ImageProgress)) model.ImageLoad {
    return .{ .id = id, .result = if (load(task, work, id, path, on_progress)) |details| .{ .ready = details } else |err| .{ .failed = err } };
}

fn load(task: *app.Task, work: *Work, id: u32, path: []const u8, on_progress: app.Handler(model.ImageProgress)) !model.ImageDetails {
    try task.checkCancel();
    var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const node = work.root.start(loadTaskName(&name_buffer, id), 0);
    defer node.end();
    work.mutex.lockUncancelable(task.io);
    task.checkCancel() catch |err| {
        work.mutex.unlock(task.io);
        return err;
    };
    work.load_watch = .{ .id = id, .task = task, .handler = on_progress };
    work.mutex.unlock(task.io);
    defer {
        work.mutex.lockUncancelable(task.io);
        if (work.load_watch) |watch| if (watch.id == id) {
            work.load_watch = null;
        };
        work.mutex.unlock(task.io);
    }
    const loaded = try work.gpa.create(Work.Loaded);
    errdefer work.gpa.destroy(loaded);
    const details = try work.open(task, loaded, path, node);
    errdefer loaded.source.deinit();
    loaded.id = id;

    work.mutex.lockUncancelable(task.io);
    task.checkCancel() catch |err| {
        work.mutex.unlock(task.io);
        return err;
    };
    const old = work.loaded;
    work.loaded = loaded;
    work.mutex.unlock(task.io);
    if (old) |replaced| work.free(replaced);
    return details;
}

pub fn unloadImage(task: *app.Task, work: *Work) void {
    work.mutex.lockUncancelable(task.io);
    task.checkCancel() catch {
        work.mutex.unlock(task.io);
        return;
    };
    const old = work.loaded;
    work.loaded = null;
    work.mutex.unlock(task.io);
    if (old) |loaded| work.free(loaded);
}

pub fn loadTaskName(buffer: []u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "openetcher-gui load {d}", .{id}) catch unreachable;
}

pub fn listDrives(task: *app.Task, file_targets: []const []const u8) model.DriveListing {
    return if (list(task, file_targets)) |drives| .{ .listed = drives } else |err| .{ .failed = err };
}

fn list(task: *app.Task, file_targets: []const []const u8) !model.DriveList {
    var drives: std.ArrayList(model.Drive) = .empty;
    errdefer {
        for (drives.items) |drive| drive.deinit(task.gpa);
        drives.deinit(task.gpa);
    }

    // `diskutil` only reads; nothing here touches a disk's contents
    const disks = try openetcher.device_api.listCandidateDisks(task.gpa, task.io, .{ .include_system = true });
    defer disks.deinit(task.gpa);
    for (disks.items) |disk| {
        var location: std.Io.Writer.Allocating = .init(task.gpa);
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
        try drives.ensureUnusedCapacity(task.gpa, 1);
        drives.appendAssumeCapacity(try drive.clone(task.gpa));
    }

    for (file_targets) |path| {
        const stat = Io.Dir.cwd().statFile(task.io, path, .{}) catch continue;
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
        try drives.ensureUnusedCapacity(task.gpa, 1);
        drives.appendAssumeCapacity(try drive.clone(task.gpa));
    }

    return .{ .items = try drives.toOwnedSlice(task.gpa) };
}
