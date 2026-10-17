const std = @import("std");
const builtin = @import("builtin");

const codec_api = @import("compression/codec.zig");
const reader_mod = @import("reader.zig");
const scan = @import("../scan.zig");

pub const Compression = codec_api.Compression;

pub const Metadata = struct {
    compression: Compression,
    encoded_size: ?u64,
    image_size: ?u64,
};

pub const SourceOptions = struct {
    max_image_size: ?u64 = null,
    /// Directory for the decoded copy of a compressed image. Defaults to
    /// `/tmp`, or the working directory on Windows.
    spool_dir: ?[]const u8 = null,
};

const default_spool_dir = if (builtin.os.tag == .windows) "." else "/tmp";
const spool_chunk_size = 1024 * 1024;

/// A random-access view over decoded image bytes, backed by an open file.
///
/// Call `reader` on the caller-owned value; the returned `Reader` points into
/// it, so the `OpenedReader` must not move while the reader is in use.
pub const OpenedReader = struct {
    region: reader_mod.FileRegion,
    owns_file: bool,

    pub fn reader(self: *OpenedReader) reader_mod.Reader {
        return self.region.reader();
    }

    pub fn close(self: *OpenedReader, io: std.Io) void {
        if (self.owns_file) self.region.file.close(io);
        self.* = undefined;
    }
};

pub const Stream = struct {
    reader: *std.Io.Reader,
    position: u64 = 0,
    max_image_size: ?u64 = null,
    context: ?*anyopaque = null,
    deinit_fn: ?*const fn (context: *anyopaque) void = null,
    translate_errors: bool = false,
    /// Optional forward jump for random-access sources. When present,
    /// `discardTo` seeks instead of reading through the skipped bytes.
    seek_to_fn: ?*const fn (context: *anyopaque, position: u64) std.Io.File.Reader.SeekError!void = null,

    pub fn read(self: *@This(), buffer: []u8) !usize {
        if (buffer.len == 0) return 0;

        var target = buffer;
        if (self.max_image_size) |limit| {
            if (self.position >= limit) {
                var extra: [1]u8 = undefined;
                const extra_count = self.reader.readSliceShort(&extra) catch |err| {
                    if (self.translate_errors) return error.InvalidCompressedImage;
                    return err;
                };
                if (extra_count != 0) return error.DecompressedImageTooLarge;
                return 0;
            }
            const remaining = limit - self.position;
            if (remaining < target.len) target = target[0..@intCast(remaining)];
        }

        const count = self.reader.readSliceShort(target) catch |err| {
            if (self.translate_errors) return error.InvalidCompressedImage;
            return err;
        };
        self.position = std.math.add(u64, self.position, count) catch return error.DecompressedImageTooLarge;
        return count;
    }

    pub fn readExactly(self: *@This(), buffer: []u8) !void {
        var completed: usize = 0;
        while (completed < buffer.len) {
            const count = try self.read(buffer[completed..]);
            if (count == 0) return error.UnexpectedEndOfImage;
            completed += count;
        }
    }

    pub fn discardTo(self: *@This(), offset: u64) !void {
        if (offset < self.position) return error.BackwardStreamRequest;
        if (self.seek_to_fn) |seek_fn| {
            const context = self.context orelse return error.BackwardStreamRequest;
            try seek_fn(context, offset);
            self.position = offset;
            return;
        }
        var scratch: [16 * 1024]u8 = undefined;
        while (self.position < offset) {
            const remaining = offset - self.position;
            const count = try self.read(scratch[0..@intCast(@min(@as(u64, scratch.len), remaining))]);
            if (count == 0) return error.UnexpectedEndOfImage;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.context) |context| {
            if (self.deinit_fn) |deinit_fn| deinit_fn(context);
        }
        self.* = undefined;
    }
};

pub const ImageSource = struct {
    context: *anyopaque,
    metadata: Metadata,
    open_stream_fn: *const fn (context: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror!Stream,
    /// Opens random access over the decoded bytes, or returns null when the
    /// source can only be streamed. `max_image_size` bounds the decoded size.
    open_reader_fn: ?*const fn (context: *anyopaque, io: std.Io, max_image_size: ?u64) anyerror!?OpenedReader = null,
    deinit_fn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) void = null,

    pub fn openStream(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !Stream {
        return self.open_stream_fn(self.context, io, allocator);
    }

    pub fn openReader(self: *@This(), io: std.Io, max_image_size: ?u64) !?OpenedReader {
        const open_fn = self.open_reader_fn orelse return null;
        return open_fn(self.context, io, max_image_size);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |deinit_fn| deinit_fn(self.context, allocator);
        self.* = undefined;
    }
};

const PathContext = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    compression: Compression,
    encoded_size: u64,
    max_image_size: ?u64,
    spool_dir: ?[]u8,
    /// Decoded copy of a compressed image, created on first random access.
    spool: ?Spool = null,
};

/// Decoded copy of a compressed image on disk. Analysis, flashing, and
/// verification all read it, so the codec runs once per source.
const Spool = struct {
    file: std.Io.File,
    io: std.Io,
    size: u64,
    /// Directory entry still to remove on close; null once unlinked.
    path: ?[]u8,

    fn close(self: *Spool, allocator: std.mem.Allocator) void {
        self.file.close(self.io);
        if (self.path) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            allocator.free(path);
        }
        self.* = undefined;
    }
};

/// Streams a file positionally, so `discardTo` seeks instead of reading.
const FileStreamContext = struct {
    file: std.Io.File,
    owns_file: bool,
    file_reader: std.Io.File.Reader,
    buffer: []u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn destroy(context: *anyopaque) void {
        const self: *FileStreamContext = @ptrCast(@alignCast(context));
        if (self.owns_file) self.file.close(self.io);
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    fn seekTo(context: *anyopaque, position: u64) std.Io.File.Reader.SeekError!void {
        const self: *FileStreamContext = @ptrCast(@alignCast(context));
        try self.file_reader.seekTo(position);
    }
};

/// Hosts the encoded-byte pipeline plus one registry-provided decoder.
const DecodedStreamContext = struct {
    file: std.Io.File,
    file_reader: std.Io.File.Reader,
    input_buffer: []u8,
    reader: *std.Io.Reader,
    translate_errors: bool,
    codec_context: ?*anyopaque,
    codec_deinit_fn: ?*const fn (std.mem.Allocator, *anyopaque) void,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn destroy(context: *anyopaque) void {
        const self: *DecodedStreamContext = @ptrCast(@alignCast(context));
        if (self.codec_context) |codec_context| {
            if (self.codec_deinit_fn) |codec_deinit_fn| codec_deinit_fn(self.allocator, codec_context);
        }
        self.file.close(self.io);
        self.allocator.free(self.input_buffer);
        self.allocator.destroy(self);
    }
};

pub fn detectCompression(magic: []const u8) Compression {
    return codec_api.detect(magic);
}

pub fn openImageSourceFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: SourceOptions) !ImageSource {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedImageSource;

    var magic: [6]u8 = undefined;
    const magic_count = try file.readPositionalAll(io, &magic, 0);
    const compression = detectCompression(magic[0..magic_count]);

    const context = try allocator.create(PathContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, path),
        .compression = compression,
        .encoded_size = stat.size,
        .max_image_size = options.max_image_size,
        .spool_dir = null,
    };
    errdefer allocator.free(context.path);
    if (options.spool_dir) |spool_dir| context.spool_dir = try allocator.dupe(u8, spool_dir);

    return .{
        .context = context,
        .metadata = .{
            .compression = compression,
            .encoded_size = stat.size,
            .image_size = if (compression == .none) stat.size else null,
        },
        .open_stream_fn = openPathStream,
        .open_reader_fn = openPathReader,
        .deinit_fn = destroyPathContext,
    };
}

pub fn openImageSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ImageSource {
    return openImageSourceFromPath(allocator, io, path, .{});
}

fn destroyPathContext(context: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *PathContext = @ptrCast(@alignCast(context));
    if (self.spool) |*spool| spool.close(allocator);
    if (self.spool_dir) |spool_dir| allocator.free(spool_dir);
    allocator.free(self.path);
    allocator.destroy(self);
}

fn openPathStream(context: *anyopaque, io: std.Io, allocator: std.mem.Allocator) !Stream {
    const source: *PathContext = @ptrCast(@alignCast(context));
    if (source.spool) |spool| return openFileStream(source, io, allocator, spool.file, false);
    switch (source.compression) {
        .none => {
            const file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
            errdefer file.close(io);
            return openFileStream(source, io, allocator, file, true);
        },
        else => return openDecodedStream(source, io, allocator),
    }
}

/// On success the stream takes `file` when `owns_file` is set.
fn openFileStream(source: *PathContext, io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, owns_file: bool) !Stream {
    const stream_context = try allocator.create(FileStreamContext);
    errdefer allocator.destroy(stream_context);
    const buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(buffer);

    stream_context.* = .{
        .file = file,
        .owns_file = owns_file,
        .file_reader = std.Io.File.Reader.init(file, io, buffer),
        .buffer = buffer,
        .allocator = allocator,
        .io = io,
    };

    return .{
        .reader = &stream_context.file_reader.interface,
        .max_image_size = source.max_image_size,
        .context = stream_context,
        .deinit_fn = FileStreamContext.destroy,
        .seek_to_fn = FileStreamContext.seekTo,
    };
}

fn openDecodedStream(source: *PathContext, io: std.Io, allocator: std.mem.Allocator) !Stream {
    var file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
    errdefer file.close(io);

    const context = try allocator.create(DecodedStreamContext);
    errdefer allocator.destroy(context);

    const input_buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(input_buffer);

    context.* = .{
        .file = file,
        .file_reader = std.Io.File.Reader.initStreaming(file, io, input_buffer),
        .input_buffer = input_buffer,
        .reader = undefined,
        .translate_errors = false,
        .codec_context = null,
        .codec_deinit_fn = null,
        .allocator = allocator,
        .io = io,
    };

    const opened = try codec_api.open(source.compression, .{
        .allocator = allocator,
        .encoded_reader = &context.file_reader.interface,
        .io = io,
        .path = source.path,
    });
    errdefer if (opened.deinit_fn) |deinit_fn| {
        if (opened.context) |codec_context| deinit_fn(allocator, codec_context);
    };

    context.reader = opened.reader;
    context.translate_errors = opened.translate_errors;
    context.codec_context = opened.context;
    context.codec_deinit_fn = opened.deinit_fn;

    return .{
        .reader = opened.reader,
        .max_image_size = source.max_image_size,
        .context = context,
        .deinit_fn = DecodedStreamContext.destroy,
        .translate_errors = opened.translate_errors,
    };
}

fn openPathReader(context: *anyopaque, io: std.Io, max_image_size: ?u64) !?OpenedReader {
    const source: *PathContext = @ptrCast(@alignCast(context));
    if (source.compression != .none) {
        const spool = try ensureSpool(source, io, max_image_size);
        return .{ .region = .init(io, spool.file, 0, spool.size), .owns_file = false };
    }

    const file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
    errdefer file.close(io);
    const size = try file.length(io);
    try checkSizeLimit(size, source.max_image_size);
    try checkSizeLimit(size, max_image_size);

    return .{ .region = .init(io, file, 0, size), .owns_file = true };
}

fn checkSizeLimit(size: u64, limit: ?u64) !void {
    if (limit) |max| if (size > max) return error.DecompressedImageTooLarge;
}

fn tighterLimit(a: ?u64, b: ?u64) ?u64 {
    const left = a orelse return b;
    const right = b orelse return left;
    return @min(left, right);
}

fn ensureSpool(source: *PathContext, io: std.Io, max_image_size: ?u64) !*const Spool {
    if (source.spool) |*spool| {
        try checkSizeLimit(spool.size, max_image_size);
        return spool;
    }
    source.spool = try createSpool(source, io, tighterLimit(source.max_image_size, max_image_size));
    return &source.spool.?;
}

/// Decodes the whole image once into a sparse file: all-zero chunks are
/// skipped rather than written, leaving holes the filesystem reads as zero.
fn createSpool(source: *PathContext, io: std.Io, limit: ?u64) !Spool {
    const allocator = source.allocator;
    var stream = try openDecodedStream(source, io, allocator);
    defer stream.deinit();
    stream.max_image_size = limit;

    var spool = try createSpoolFile(allocator, io, source.spool_dir orelse default_spool_dir);
    errdefer spool.close(allocator);

    const buffer = try allocator.alloc(u8, spool_chunk_size);
    defer allocator.free(buffer);

    var size: u64 = 0;
    while (true) {
        const count = try stream.read(buffer);
        if (count == 0) break;
        const chunk = buffer[0..count];
        if (!scan.isZero(chunk)) spool.file.writePositionalAll(io, chunk, size) catch |err| return switch (err) {
            error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => error.SpoolDirectoryFull,
            else => |other| other,
        };
        size += count;
    }
    spool.file.setLength(io, size) catch |err| return switch (err) {
        error.FileTooBig => error.SpoolDirectoryFull,
        else => |other| other,
    };
    spool.size = size;
    return spool;
}

fn createSpoolFile(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !Spool {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var id: [8]u8 = undefined;
        io.random(&id);
        const path = try std.fmt.allocPrint(allocator, "{s}{c}openetcher-{x:0>16}.spool", .{ dir, std.fs.path.sep, std.mem.readInt(u64, &id, .little) });
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .exclusive = true }) catch |err| {
            allocator.free(path);
            switch (err) {
                error.PathAlreadyExists => if (attempt < 8) continue else return err,
                error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.SpoolDirectoryUnavailable,
                else => return err,
            }
        };

        // POSIX keeps an unlinked file alive through its open handle, so
        // removing the name now means an interrupted run cannot leak it.
        if (builtin.os.tag != .windows) {
            if (std.Io.Dir.cwd().deleteFile(io, path)) |_| {
                allocator.free(path);
                return .{ .file = file, .io = io, .size = 0, .path = null };
            } else |_| {}
        }
        return .{ .file = file, .io = io, .size = 0, .path = path };
    }
}

/// Test fixtures shared with other modules' tests.
pub const testing = if (builtin.is_test) struct {
    /// Writes `bytes` gzip-compressed to `sub_path` and returns its real path.
    pub fn writeGzip(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) ![:0]u8 {
        var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
        defer output.deinit();
        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);

        var compress = try std.compress.flate.Compress.init(&output.writer, window, .gzip, .default);
        try compress.writer.writeAll(bytes);
        try compress.finish();

        var file = try dir.createFile(io, sub_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, output.written());
        return dir.realPathFileAlloc(io, sub_path, allocator);
    }

    /// A mostly-zero image with marker bytes, so spooling exercises holes.
    pub fn sparseImage(allocator: std.mem.Allocator) ![]u8 {
        const bytes = try allocator.alloc(u8, 3 * spool_chunk_size + 512);
        @memset(bytes, 0);
        @memcpy(bytes[100..][0..4], "head");
        @memcpy(bytes[2 * spool_chunk_size + 7 ..][0..3], "mid");
        @memcpy(bytes[bytes.len - 4 ..], "tail");
        return bytes;
    }
} else struct {};

fn countEntries(io: std.Io, dir: std.Io.Dir) !usize {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "compression detection uses magic bytes" {
    try std.testing.expectEqual(Compression.gzip, detectCompression(&.{ 0x1f, 0x8b, 0x08 }));
    try std.testing.expectEqual(Compression.xz, detectCompression(&.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 }));
    try std.testing.expectEqual(Compression.zstd, detectCompression(&.{ 0x28, 0xb5, 0x2f, 0xfd }));
    try std.testing.expectEqual(Compression.bzip2, detectCompression("BZh9"));
    try std.testing.expectEqual(Compression.none, detectCompression("image.img.gz"));
}

test "stream rejects backward movement" {
    var reader = std.Io.Reader.fixed("abcdef");
    var stream = Stream{ .reader = &reader };
    var output: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try stream.read(&output));
    try std.testing.expectError(error.BackwardStreamRequest, stream.discardTo(1));
}

test "raw source opens independent streams" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "raw.img", .{ .read = true });
    try file.writeStreamingAll(io, "abcdef");
    try file.sync(io);
    file.close(io);

    const path = try tmp.dir.realPathFileAlloc(io, "raw.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var image_source = try openImageSourceFromPath(std.testing.allocator, io, path, .{});
    defer image_source.deinit(std.testing.allocator);

    var first = try image_source.openStream(io, std.testing.allocator);
    defer first.deinit();
    var first_bytes: [3]u8 = undefined;
    try first.readExactly(&first_bytes);
    try std.testing.expectEqualSlices(u8, "abc", &first_bytes);

    var second = try image_source.openStream(io, std.testing.allocator);
    defer second.deinit();
    var second_bytes: [6]u8 = undefined;
    try second.readExactly(&second_bytes);
    try std.testing.expectEqualSlices(u8, "abcdef", &second_bytes);
}

test "raw source streams seek over skipped bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(io, "sparse.img", .{ .read = true });
        defer file.close(io);
        try file.setLength(io, 64 * 1024 * 1024);
        try file.writePositionalAll(io, "tail", 64 * 1024 * 1024 - 4);
    }

    const path = try tmp.dir.realPathFileAlloc(io, "sparse.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var image_source = try openImageSourceFromPath(std.testing.allocator, io, path, .{});
    defer image_source.deinit(std.testing.allocator);

    var stream = try image_source.openStream(io, std.testing.allocator);
    defer stream.deinit();
    try std.testing.expect(stream.seek_to_fn != null);
    try stream.discardTo(64 * 1024 * 1024 - 4);

    var tail: [4]u8 = undefined;
    try stream.readExactly(&tail);
    try std.testing.expectEqualStrings("tail", &tail);
}

test "stream enforces decoded size limit" {
    var reader = std.Io.Reader.fixed("abcdef");
    var stream = Stream{ .reader = &reader, .max_image_size = 4 };
    var bytes: [4]u8 = undefined;
    try stream.readExactly(&bytes);
    try std.testing.expectError(error.DecompressedImageTooLarge, stream.read(&bytes));
}

test "compressed sources spool once and replay from the spool" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "spool", .default_dir);
    var spool_dir = try tmp.dir.openDir(io, "spool", .{ .iterate = true });
    defer spool_dir.close(io);
    const spool_path = try tmp.dir.realPathFileAlloc(io, "spool", allocator);
    defer allocator.free(spool_path);

    const bytes = try testing.sparseImage(allocator);
    defer allocator.free(bytes);
    const path = try testing.writeGzip(allocator, io, tmp.dir, "image.img.gz", bytes);
    defer allocator.free(path);

    var image_source = try openImageSourceFromPath(allocator, io, path, .{ .spool_dir = spool_path });
    defer image_source.deinit(allocator);

    var opened = (try image_source.openReader(io, null)).?;
    defer opened.close(io);
    const r = opened.reader();
    try std.testing.expectEqual(@as(u64, bytes.len), r.size);
    var mid: [3]u8 = undefined;
    try r.readExactlyAt(io, &mid, 2 * spool_chunk_size + 7);
    try std.testing.expectEqualStrings("mid", &mid);

    // The spool is unlinked on POSIX, so nothing is left behind on a crash.
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(usize, 0), try countEntries(io, spool_dir));

    // With the encoded file gone, streams can only come from the spool.
    try tmp.dir.deleteFile(io, "image.img.gz");
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    try std.testing.expect(stream.seek_to_fn != null);
    const replayed = try allocator.alloc(u8, bytes.len);
    defer allocator.free(replayed);
    try stream.readExactly(replayed);
    try std.testing.expectEqualSlices(u8, bytes, replayed);

    var again = (try image_source.openReader(io, null)).?;
    again.close(io);
    try std.testing.expectError(error.DecompressedImageTooLarge, image_source.openReader(io, bytes.len - 1));
}

test "spooling enforces the decoded size limit and cleans up" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "spool", .default_dir);
    var spool_dir = try tmp.dir.openDir(io, "spool", .{ .iterate = true });
    defer spool_dir.close(io);
    const spool_path = try tmp.dir.realPathFileAlloc(io, "spool", allocator);
    defer allocator.free(spool_path);

    const bytes = try testing.sparseImage(allocator);
    defer allocator.free(bytes);
    const path = try testing.writeGzip(allocator, io, tmp.dir, "image.img.gz", bytes);
    defer allocator.free(path);

    var image_source = try openImageSourceFromPath(allocator, io, path, .{ .spool_dir = spool_path, .max_image_size = spool_chunk_size });
    defer image_source.deinit(allocator);
    try std.testing.expectError(error.DecompressedImageTooLarge, image_source.openReader(io, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntries(io, spool_dir));
}

test "spooling releases everything on allocation failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spool_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(spool_path);

    const bytes = try testing.sparseImage(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const path = try testing.writeGzip(std.testing.allocator, io, tmp.dir, "image.img.gz", bytes);
    defer std.testing.allocator.free(path);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, spoolAndRead, .{ io, path, spool_path });
}

fn spoolAndRead(allocator: std.mem.Allocator, io: std.Io, path: []const u8, spool_path: []const u8) !void {
    var image_source = try openImageSourceFromPath(allocator, io, path, .{ .spool_dir = spool_path });
    defer image_source.deinit(allocator);
    var opened = (try image_source.openReader(io, null)).?;
    defer opened.close(io);
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
}
