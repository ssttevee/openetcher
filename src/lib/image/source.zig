const std = @import("std");
const builtin = @import("builtin");

const codec_api = @import("compression/codec.zig");
const progress_units = @import("../progress.zig");
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
    /// Parent for a node that tracks decoding a compressed image into its
    /// spool, which can take minutes before anything is flashed. It must
    /// not end while the source might still spool; see
    /// `ImageSource.progress`.
    progress: std.Progress.Node = .none,
};

const default_spool_dir = if (builtin.os.tag == .windows) "." else "/tmp";
const spool_chunk_size = 1024 * 1024;
/// Buffer between a file and the stream reading it.
const stream_buffer_len = 64 * 1024;

const File = std.Io.File;

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

/// A forward-only pass over decoded image bytes.
pub const Stream = struct {
    position: u64 = 0,
    max_image_size: ?u64 = null,
    backend: Backend,

    pub const ReadError = File.Reader.Error || error{ InvalidCompressedImage, DecompressedImageTooLarge };
    pub const ReadExactError = ReadError || error{UnexpectedEndOfImage};
    pub const DiscardError = ReadExactError || File.Reader.SeekError || error{BackwardStreamRequest};

    /// Each backend lives on the heap: readers and decoders point into it,
    /// so it must stay put while the `Stream` value moves.
    pub const Backend = union(enum) {
        /// The image itself, or its spool, read positionally so `discardTo`
        /// seeks instead of reading.
        file: *FileBackend,
        /// An encoded file piped through a codec; skipping means decoding.
        decoded: *DecodedBackend,
    };

    pub const FileBackend = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        owns_file: bool,
        reader: File.Reader,
        buffer: [stream_buffer_len]u8,
    };

    pub const DecodedBackend = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        file: File,
        encoded: File.Reader,
        buffer: [stream_buffer_len]u8,
        decoder: codec_api.Decoder,
    };

    /// Streams `file` from its start. The stream closes `file` on `deinit`
    /// when `owns_file` is set; on failure the caller keeps it.
    pub fn openFile(allocator: std.mem.Allocator, io: std.Io, file: File, owns_file: bool) error{OutOfMemory}!Stream {
        const backend = try allocator.create(FileBackend);
        backend.allocator = allocator;
        backend.io = io;
        backend.owns_file = owns_file;
        backend.reader = .init(file, io, &backend.buffer);
        return .{ .backend = .{ .file = backend } };
    }

    /// Opens `path` and decodes it with the codec for `compression`.
    fn openDecoded(allocator: std.mem.Allocator, io: std.Io, path: []const u8, compression: Compression) !Stream {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false });
        errdefer file.close(io);

        const backend = try allocator.create(DecodedBackend);
        errdefer allocator.destroy(backend);
        backend.allocator = allocator;
        backend.io = io;
        backend.file = file;
        backend.encoded = .initStreaming(file, io, &backend.buffer);
        try codec_api.initDecoder(&backend.decoder, compression, .{
            .allocator = allocator,
            .encoded_reader = &backend.encoded.interface,
            .io = io,
            .path = path,
        });
        return .{ .backend = .{ .decoded = backend } };
    }

    /// How many encoded bytes the codec has consumed, or null when nothing
    /// is decoded or the codec reads the file itself.
    pub fn encodedPosition(self: *const Stream) ?u64 {
        return switch (self.backend) {
            .file => null,
            .decoded => |backend| if (codec_api.readsEncodedReader(&backend.decoder)) backend.encoded.logicalPos() else null,
        };
    }

    fn interface(self: *const Stream) *std.Io.Reader {
        return switch (self.backend) {
            .file => |backend| &backend.reader.interface,
            .decoded => |backend| codec_api.decodedReader(&backend.decoder),
        };
    }

    /// The error behind a `ReadFailed` from `interface`.
    fn readFailure(self: *const Stream) ReadError {
        return switch (self.backend) {
            .file => |backend| backend.reader.err orelse error.InputOutput,
            // A failed file read reaches the decoder as `ReadFailed` too, so
            // check the file first; anything else is the codec rejecting
            // its input.
            .decoded => |backend| backend.encoded.err orelse error.InvalidCompressedImage,
        };
    }

    pub fn read(self: *Stream, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;

        var target = buffer;
        if (self.max_image_size) |limit| {
            if (self.position >= limit) {
                var extra: [1]u8 = undefined;
                const extra_count = self.interface().readSliceShort(&extra) catch return self.readFailure();
                if (extra_count != 0) return error.DecompressedImageTooLarge;
                return 0;
            }
            const remaining = limit - self.position;
            if (remaining < target.len) target = target[0..@intCast(remaining)];
        }

        const count = self.interface().readSliceShort(target) catch return self.readFailure();
        self.position = std.math.add(u64, self.position, count) catch return error.DecompressedImageTooLarge;
        return count;
    }

    pub fn readExactly(self: *Stream, buffer: []u8) ReadExactError!void {
        var completed: usize = 0;
        while (completed < buffer.len) {
            const count = try self.read(buffer[completed..]);
            if (count == 0) return error.UnexpectedEndOfImage;
            completed += count;
        }
    }

    pub fn discardTo(self: *Stream, offset: u64) DiscardError!void {
        if (offset < self.position) return error.BackwardStreamRequest;
        switch (self.backend) {
            .file => |backend| {
                try backend.reader.seekTo(offset);
                self.position = offset;
                return;
            },
            .decoded => {},
        }
        var scratch: [16 * 1024]u8 = undefined;
        while (self.position < offset) {
            const remaining = offset - self.position;
            const count = try self.read(scratch[0..@intCast(@min(@as(u64, scratch.len), remaining))]);
            if (count == 0) return error.UnexpectedEndOfImage;
        }
    }

    pub fn deinit(self: *Stream) void {
        switch (self.backend) {
            .file => |backend| {
                if (backend.owns_file) backend.reader.file.close(backend.io);
                backend.allocator.destroy(backend);
            },
            .decoded => |backend| {
                codec_api.deinitDecoder(&backend.decoder);
                backend.file.close(backend.io);
                backend.allocator.destroy(backend);
            },
        }
        self.* = undefined;
    }
};

/// An image file, possibly compressed, that analysis, flashing, and
/// verification can each read in turn.
pub const ImageSource = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    metadata: Metadata,
    max_image_size: ?u64,
    spool_dir: ?[]u8,
    /// Parent for the spooling node, from `SourceOptions.progress`. Set it
    /// directly to report spooling under a node started later.
    progress: std.Progress.Node,
    content: Content,

    pub const Content = union(enum) {
        /// The file is the image.
        raw,
        /// The file must be decoded on every pass until something needs
        /// random access.
        encoded: Compression,
        /// The file was decoded once into a spool, which every later pass
        /// reads instead.
        spooled: Spool,
    };

    pub fn openStream(self: *ImageSource, io: std.Io, allocator: std.mem.Allocator) !Stream {
        var stream = switch (self.content) {
            .raw => raw: {
                const file = try std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .read_only, .allow_directory = false });
                errdefer file.close(io);
                break :raw try Stream.openFile(allocator, io, file, true);
            },
            .encoded => |compression| try Stream.openDecoded(allocator, io, self.path, compression),
            .spooled => |spool| try Stream.openFile(allocator, io, spool.file, false),
        };
        stream.max_image_size = self.max_image_size;
        return stream;
    }

    /// Opens random access over the decoded bytes, decoding a compressed
    /// image into a spool the first time. `max_image_size` bounds the
    /// decoded size.
    pub fn openReader(self: *ImageSource, io: std.Io, max_image_size: ?u64) !OpenedReader {
        switch (self.content) {
            .raw => {
                const file = try std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .read_only, .allow_directory = false });
                errdefer file.close(io);
                const size = try file.length(io);
                try checkSizeLimit(size, self.max_image_size);
                try checkSizeLimit(size, max_image_size);
                return .{ .region = .init(io, file, 0, size), .owns_file = true };
            },
            .encoded => |compression| {
                // Bound first: assigning `.{ .spooled = try ... }` directly
                // would switch the tag before a failed decode could return.
                const spool = try createSpool(self, io, compression, tighterLimit(self.max_image_size, max_image_size));
                self.content = .{ .spooled = spool };
                return .{ .region = .init(io, spool.file, 0, spool.size), .owns_file = false };
            },
            .spooled => |spool| {
                try checkSizeLimit(spool.size, max_image_size);
                return .{ .region = .init(io, spool.file, 0, spool.size), .owns_file = false };
            },
        }
    }

    pub fn deinit(self: *ImageSource) void {
        switch (self.content) {
            .raw, .encoded => {},
            .spooled => |*spool| spool.close(self.allocator),
        }
        if (self.spool_dir) |spool_dir| self.allocator.free(spool_dir);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

/// Decoded copy of a compressed image on disk. Analysis, flashing, and
/// verification all read it, so the codec runs once per source.
pub const Spool = struct {
    file: File,
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

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const spool_dir = if (options.spool_dir) |dir| try allocator.dupe(u8, dir) else null;

    return .{
        .allocator = allocator,
        .path = owned_path,
        .metadata = .{
            .compression = compression,
            .encoded_size = stat.size,
            .image_size = if (compression == .none) stat.size else null,
        },
        .max_image_size = options.max_image_size,
        .spool_dir = spool_dir,
        .progress = options.progress,
        .content = if (compression == .none) .raw else .{ .encoded = compression },
    };
}

pub fn openImageSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ImageSource {
    return openImageSourceFromPath(allocator, io, path, .{});
}

fn checkSizeLimit(size: u64, limit: ?u64) error{DecompressedImageTooLarge}!void {
    if (limit) |max| if (size > max) return error.DecompressedImageTooLarge;
}

fn tighterLimit(a: ?u64, b: ?u64) ?u64 {
    const left = a orelse return b;
    const right = b orelse return left;
    return @min(left, right);
}

/// Decodes the whole image once into a sparse file: all-zero chunks are
/// skipped rather than written, leaving holes the filesystem reads as zero.
fn createSpool(source: *const ImageSource, io: std.Io, compression: Compression, limit: ?u64) !Spool {
    const allocator = source.allocator;
    var stream = try Stream.openDecoded(allocator, io, source.path, compression);
    defer stream.deinit();
    stream.max_image_size = limit;

    var spool = try createSpoolFile(allocator, io, source.spool_dir orelse default_spool_dir);
    errdefer spool.close(allocator);

    const buffer = try allocator.alloc(u8, spool_chunk_size);
    defer allocator.free(buffer);

    // The decoded size is unknown until the end, so measure how much of the
    // encoded file the codec has consumed instead. A codec that reads the
    // file itself leaves only the decoded count, with no total.
    const progress = if (stream.encodedPosition() != null)
        source.progress.start("compressed KiB decoded", progress_units.fromBytes(source.metadata.encoded_size orelse 0))
    else
        source.progress.start("KiB decompressed", 0);
    defer progress.end();

    var size: u64 = 0;
    while (true) {
        const count = try stream.read(buffer);
        if (count == 0) break;
        progress.setCompletedItems(progress_units.fromBytes(stream.encodedPosition() orelse size + count));
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
        const path = try std.fmt.allocPrint(allocator, "{s}{c}openetcher-{x:0>16}.spool", .{ dir, std.Io.Dir.path.sep, std.mem.readInt(u64, &id, .little) });
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
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "raw.img", .data = "abcdef" });
    var file = try tmp.dir.openFile(io, "raw.img", .{});
    defer file.close(io);

    var stream = try Stream.openFile(std.testing.allocator, io, file, false);
    defer stream.deinit();
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
    defer image_source.deinit();

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
    defer image_source.deinit();

    var stream = try image_source.openStream(io, std.testing.allocator);
    defer stream.deinit();
    try std.testing.expect(stream.backend == .file);
    try stream.discardTo(64 * 1024 * 1024 - 4);

    var tail: [4]u8 = undefined;
    try stream.readExactly(&tail);
    try std.testing.expectEqualStrings("tail", &tail);
}

test "stream enforces decoded size limit" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testing.writeGzip(allocator, io, tmp.dir, "image.img.gz", "abcdef");
    defer allocator.free(path);

    var image_source = try openImageSourceFromPath(allocator, io, path, .{ .max_image_size = 4 });
    defer image_source.deinit();
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    try std.testing.expect(stream.backend == .decoded);
    var bytes: [4]u8 = undefined;
    try stream.readExactly(&bytes);
    try std.testing.expectEqualStrings("abcd", &bytes);
    try std.testing.expectError(error.DecompressedImageTooLarge, stream.read(&bytes));
}

test "decoded streams measure the encoded input they consumed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try testing.sparseImage(allocator);
    defer allocator.free(bytes);
    const path = try testing.writeGzip(allocator, io, tmp.dir, "image.img.gz", bytes);
    defer allocator.free(path);
    var image_source = try openImageSourceFromPath(allocator, io, path, .{});
    defer image_source.deinit();

    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    try std.testing.expectEqual(@as(?u64, 0), stream.encodedPosition());
    const decoded = try allocator.alloc(u8, bytes.len);
    defer allocator.free(decoded);
    try stream.readExactly(decoded);
    var tail: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try stream.read(&tail));
    // Spooling progress counts against this total, so it must end there.
    try std.testing.expectEqual(image_source.metadata.encoded_size, stream.encodedPosition());

    // Raw images are not decoded, so there is no encoded position.
    try tmp.dir.writeFile(io, .{ .sub_path = "raw.img", .data = "abcdef" });
    const raw_path = try tmp.dir.realPathFileAlloc(io, "raw.img", allocator);
    defer allocator.free(raw_path);
    var raw_source = try openImageSourceFromPath(allocator, io, raw_path, .{});
    defer raw_source.deinit();
    var raw_stream = try raw_source.openStream(io, allocator);
    defer raw_stream.deinit();
    try std.testing.expectEqual(null, raw_stream.encodedPosition());
}

test "corrupt compressed input reports InvalidCompressedImage" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A gzip header followed by bytes that are not a deflate stream.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.gz", .data = &.{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff } });
    const path = try tmp.dir.realPathFileAlloc(io, "bad.gz", allocator);
    defer allocator.free(path);

    var image_source = try openImageSourceFromPath(allocator, io, path, .{});
    defer image_source.deinit();
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
    var bytes: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidCompressedImage, stream.readExactly(&bytes));
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
    defer image_source.deinit();

    var opened = try image_source.openReader(io, null);
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
    try std.testing.expect(stream.backend == .file);
    const replayed = try allocator.alloc(u8, bytes.len);
    defer allocator.free(replayed);
    try stream.readExactly(replayed);
    try std.testing.expectEqualSlices(u8, bytes, replayed);

    var again = try image_source.openReader(io, null);
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
    defer image_source.deinit();
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
    defer image_source.deinit();
    var opened = try image_source.openReader(io, null);
    defer opened.close(io);
    var stream = try image_source.openStream(io, allocator);
    defer stream.deinit();
}
