const std = @import("std");

const codec_api = @import("compression/codec.zig");

pub const Compression = codec_api.Compression;

pub const Metadata = struct {
    compression: Compression,
    encoded_size: ?u64,
    image_size: ?u64,
};

pub const SourceOptions = struct {
    max_image_size: ?u64 = null,
};

pub const RandomAccessReader = struct {
    context: *anyopaque,
    size: u64,
    read_at_fn: *const fn (context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) anyerror!usize,
    deinit_fn: ?*const fn (context: *anyopaque) void = null,

    pub fn readAt(self: *@This(), io: std.Io, buffer: []u8, offset: u64) !usize {
        return self.read_at_fn(self.context, io, buffer, offset);
    }

    pub fn deinit(self: *@This()) void {
        if (self.deinit_fn) |deinit_fn| deinit_fn(self.context);
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
    seek_to_fn: ?*const fn (context: *anyopaque, position: u64) anyerror!void = null,

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
    open_random_access_fn: ?*const fn (context: *anyopaque, io: std.Io) anyerror!?RandomAccessReader = null,
    deinit_fn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) void = null,

    pub fn openStream(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !Stream {
        return self.open_stream_fn(self.context, io, allocator);
    }

    pub fn openRandomAccess(self: *@This(), io: std.Io) !?RandomAccessReader {
        const open_fn = self.open_random_access_fn orelse return null;
        return open_fn(self.context, io);
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
};

const RawStreamContext = struct {
    file: std.Io.File,
    file_reader: std.Io.File.Reader,
    buffer: []u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn destroy(context: *anyopaque) void {
        const self: *RawStreamContext = @ptrCast(@alignCast(context));
        self.file.close(self.io);
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
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

fn codecFor(compression: Compression) ?*const codec_api.Codec {
    for (&codec_api.codecs) |*candidate| {
        if (candidate.id == compression) return candidate;
    }
    return null;
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
    };
    errdefer allocator.free(context.path);

    return .{
        .context = context,
        .metadata = .{
            .compression = compression,
            .encoded_size = stat.size,
            .image_size = if (compression == .none) stat.size else null,
        },
        .open_stream_fn = openPathStream,
        .open_random_access_fn = if (compression == .none) openPathRandomAccess else null,
        .deinit_fn = destroyPathContext,
    };
}

pub fn openImageSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ImageSource {
    return openImageSourceFromPath(allocator, io, path, .{});
}

fn destroyPathContext(context: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *PathContext = @ptrCast(@alignCast(context));
    allocator.free(self.path);
    allocator.destroy(self);
}

fn openPathStream(context: *anyopaque, io: std.Io, allocator: std.mem.Allocator) !Stream {
    const source: *PathContext = @ptrCast(@alignCast(context));
    return switch (source.compression) {
        .none => openRawStream(source, io, allocator),
        else => openDecodedStream(source, io, allocator),
    };
}

fn openRawStream(source: *PathContext, io: std.Io, allocator: std.mem.Allocator) !Stream {
    var file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
    errdefer file.close(io);

    const stream_context = try allocator.create(RawStreamContext);
    errdefer allocator.destroy(stream_context);
    const buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(buffer);

    stream_context.* = .{
        .file = file,
        .file_reader = std.Io.File.Reader.initStreaming(file, io, buffer),
        .buffer = buffer,
        .allocator = allocator,
        .io = io,
    };

    return .{
        .reader = &stream_context.file_reader.interface,
        .max_image_size = source.max_image_size,
        .context = stream_context,
        .deinit_fn = RawStreamContext.destroy,
    };
}

fn openDecodedStream(source: *PathContext, io: std.Io, allocator: std.mem.Allocator) !Stream {
    const codec = codecFor(source.compression) orelse return error.UnsupportedCompression;

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

    const opened = codec.open(.{
        .allocator = allocator,
        .encoded_reader = &context.file_reader.interface,
        .io = io,
        .path = source.path,
        .max_image_size = source.max_image_size,
    }) catch |err| {
        // The context owns the file and input buffer; free them before bubbling.
        allocator.free(input_buffer);
        allocator.destroy(context);
        file.close(io);
        return err;
    };
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

fn openPathRandomAccess(context: *anyopaque, io: std.Io) !?RandomAccessReader {
    _ = io;
    return .{ .context = context, .size = @as(*PathContext, @ptrCast(@alignCast(context))).encoded_size, .read_at_fn = readPathAt };
}

fn readPathAt(context: *anyopaque, io: std.Io, buffer: []u8, offset: u64) !usize {
    const source: *PathContext = @ptrCast(@alignCast(context));
    var file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
    defer file.close(io);
    return file.readPositionalAll(io, buffer, offset);
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

test "stream enforces decoded size limit" {
    var reader = std.Io.Reader.fixed("abcdef");
    var stream = Stream{ .reader = &reader, .max_image_size = 4 };
    var bytes: [4]u8 = undefined;
    try stream.readExactly(&bytes);
    try std.testing.expectError(error.DecompressedImageTooLarge, stream.read(&bytes));
}
