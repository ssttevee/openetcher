const std = @import("std");
const builtin = @import("builtin");

const codec_api = @import("codec.zig");

/// bzip2 has no in-tree decoder, so this codec runs the `bzip2` executable
/// and streams its stdout. Nothing is buffered beyond one pipe read, so the
/// spool and full-stream flashing see the same streaming behavior as the
/// native codecs, and `Stream` enforces the decoded size limit as it reads.
///
/// A failing `bzip2` simply stops writing, which on its own would look like
/// a shorter valid image. End of stream therefore waits for the process and
/// turns a non-zero exit into a read failure.
const ChildStream = struct {
    io: std.Io,
    child: std.process.Child,
    pipe: std.Io.File.Reader,
    buffer: []u8,
    /// Set once the process has been waited for, with its outcome.
    exited: ?bool = null,
    interface: std.Io.Reader,

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChildStream = @fieldParentPtr("interface", r);
        if (self.exited) |succeeded| return if (succeeded) error.EndOfStream else error.ReadFailed;
        return self.pipe.interface.stream(w, limit) catch |err| switch (err) {
            error.EndOfStream => {
                const term = self.child.wait(self.io) catch {
                    self.exited = false;
                    return error.ReadFailed;
                };
                self.exited = term.success();
                return if (term.success()) error.EndOfStream else error.ReadFailed;
            },
            else => |other| other,
        };
    }

    fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *ChildStream = @ptrCast(@alignCast(context));
        // Stopped early, by an error or the size limit: end the process.
        if (self.exited == null) self.child.kill(self.io);
        allocator.free(self.buffer);
        allocator.destroy(self);
    }
};

pub fn open(args: codec_api.OpenArgs) !codec_api.Opened {
    const self = try args.allocator.create(ChildStream);
    errdefer args.allocator.destroy(self);
    self.buffer = try args.allocator.alloc(u8, 64 * 1024);
    errdefer args.allocator.free(self.buffer);

    self.child = std.process.spawn(args.io, .{
        .argv = &.{ "bzip2", "-dc", args.path },
        .stdin = .ignore,
        .stdout = .pipe,
        // Unread, a stderr pipe could fill and stall bzip2; the exit status
        // already reports failure.
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.Bzip2Unavailable,
        else => |other| return other,
    };
    self.io = args.io;
    self.exited = null;
    self.pipe = std.Io.File.Reader.initStreaming(self.child.stdout.?, args.io, self.buffer);
    self.interface = .{
        .vtable = &.{ .stream = ChildStream.stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };

    return .{
        .reader = &self.interface,
        .translate_errors = true,
        .context = self,
        .deinit_fn = ChildStream.deinit,
    };
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .bzip2;
pub const magic: []const u8 = "BZh";

const source = @import("../source.zig");

/// Compresses `bytes` with the system `bzip2` into `dir/sub_path`, or skips
/// the test when the tool is missing.
fn writeBzip2(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) ![:0]u8 {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
    const path = try dir.realPathFileAlloc(io, sub_path, allocator);
    defer allocator.free(path);
    const result = std.process.run(allocator, io, .{ .argv = &.{ "bzip2", "-1", path } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |other| return other,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.Bzip2Failed;

    const compressed = try std.fmt.allocPrint(allocator, "{s}.bz2", .{sub_path});
    defer allocator.free(compressed);
    return dir.realPathFileAlloc(io, compressed, allocator);
}

fn testImage(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 8 * 1024 * 1024);
    for (bytes, 0..) |*byte, index| byte.* = if (index % 4096 < 64) @truncate(index / 4096) else 0;
    return bytes;
}

test "bzip2 sources stream without buffering the image" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testImage(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const path = try writeBzip2(std.testing.allocator, io, tmp.dir, "image.img", bytes);
    defer std.testing.allocator.free(path);

    // An eighth of the image: holding the decoded output would not fit.
    const arena_buffer = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(arena_buffer);
    var fixed = std.heap.FixedBufferAllocator.init(arena_buffer);
    const allocator = fixed.allocator();

    var image_source = try source.openImageSourceFromPath(allocator, io, path, .{});
    defer image_source.deinit(allocator);
    try std.testing.expectEqual(codec_api.Compression.bzip2, image_source.metadata.compression);

    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    var chunk: [64 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const count = try stream.read(&chunk);
        if (count == 0) break;
        try std.testing.expectEqualSlices(u8, bytes[offset..][0..count], chunk[0..count]);
        offset += count;
    }
    try std.testing.expectEqual(bytes.len, offset);
}

test "truncated bzip2 input fails instead of yielding a short image" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testImage(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const path = try writeBzip2(std.testing.allocator, io, tmp.dir, "image.img", bytes);
    defer std.testing.allocator.free(path);
    {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, (try file.length(io)) / 2);
    }

    var image_source = try source.openImageSourceFromPath(std.testing.allocator, io, path, .{});
    defer image_source.deinit(std.testing.allocator);
    var stream = try image_source.openStream(io, std.testing.allocator);
    defer stream.deinit();
    var chunk: [64 * 1024]u8 = undefined;
    const result = while (true) {
        const count = stream.read(&chunk) catch |err| break err;
        if (count == 0) break error.TestUnexpectedEndOfImage;
    };
    try std.testing.expectEqual(error.InvalidCompressedImage, result);
}

test "closing a bzip2 stream early ends the process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testImage(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const path = try writeBzip2(std.testing.allocator, io, tmp.dir, "image.img", bytes);
    defer std.testing.allocator.free(path);

    var image_source = try source.openImageSourceFromPath(std.testing.allocator, io, path, .{ .max_image_size = 1024 * 1024 });
    defer image_source.deinit(std.testing.allocator);
    var stream = try image_source.openStream(io, std.testing.allocator);
    defer stream.deinit();
    var chunk: [64 * 1024]u8 = undefined;
    const result = while (true) {
        const count = stream.read(&chunk) catch |err| break err;
        if (count == 0) break error.TestExpectedSizeLimit;
    };
    // `deinit` kills bzip2 mid-stream; the testing allocator catches leaks.
    try std.testing.expectEqual(error.DecompressedImageTooLarge, result);
}
