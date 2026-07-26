const std = @import("std");

pub const Compression = enum {
    none,
    gzip,
    xz,
    zstd,
    bzip2,
};

pub const Metadata = struct {
    compression: Compression,
    encoded_size: ?u64,
    image_size: ?u64,
};

pub const SourcePolicy = enum {
    streaming,
    materialize_if_needed,
    materialize,
};

pub const SourceOptions = struct {
    policy: SourcePolicy = .streaming,
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

const EagerStreamContext = struct {
    decoded: []u8,
    reader: std.Io.Reader,
    allocator: std.mem.Allocator,

    fn destroy(context: *anyopaque) void {
        const self: *EagerStreamContext = @ptrCast(@alignCast(context));
        self.allocator.free(self.decoded);
        self.allocator.destroy(self);
    }
};

const Decoder = union(Compression) {
    none: void,
    gzip: std.compress.flate.Decompress,
    xz: std.compress.xz.Decompress,
    zstd: std.compress.zstd.Decompress,
    bzip2: void,
};

const DecodedStreamContext = struct {
    file: std.Io.File,
    file_reader: std.Io.File.Reader,
    input_buffer: []u8,
    decoder_buffer: []u8,
    decoder: Decoder,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    io: std.Io,
    compression: Compression,

    fn destroy(context: *anyopaque) void {
        const self: *DecodedStreamContext = @ptrCast(@alignCast(context));
        switch (self.compression) {
            .xz => self.decoder.xz.deinit(),
            else => {},
        }
        self.file.close(self.io);
        self.allocator.free(self.input_buffer);
        self.allocator.free(self.decoder_buffer);
        self.allocator.destroy(self);
    }
};

pub fn detectCompression(magic: []const u8) Compression {
    const gzip_magic = &.{ 0x1f, 0x8b };
    const xz_magic = &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 };
    const zstd_magic = &.{ 0x28, 0xb5, 0x2f, 0xfd };
    const bzip2_magic = "BZh";
    if (hasMagicPrefix(magic, gzip_magic)) return .gzip;
    if (hasMagicPrefix(magic, xz_magic)) return .xz;
    if (hasMagicPrefix(magic, zstd_magic)) return .zstd;
    if (hasMagicPrefix(magic, bzip2_magic)) return .bzip2;
    return .none;
}

fn hasMagicPrefix(bytes: []const u8, magic: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes.len < magic.len) return std.mem.eql(u8, bytes, magic[0..bytes.len]);
    return std.mem.eql(u8, bytes[0..magic.len], magic);
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
        .bzip2 => openBzip2Stream(source, io, allocator),
        .gzip, .xz, .zstd => openDecodedStream(source, io, allocator),
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
    var file = try std.Io.Dir.cwd().openFile(io, source.path, .{ .mode = .read_only, .allow_directory = false });
    errdefer file.close(io);

    const context = try allocator.create(DecodedStreamContext);
    errdefer allocator.destroy(context);

    const input_buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(input_buffer);
    var decoder_buffer: []u8 = &.{};
    errdefer if (decoder_buffer.len != 0) allocator.free(decoder_buffer);

    context.* = undefined;
    context.file = file;
    context.file_reader = std.Io.File.Reader.initStreaming(file, io, input_buffer);
    context.input_buffer = input_buffer;
    context.decoder_buffer = decoder_buffer;
    context.allocator = allocator;
    context.io = io;
    context.compression = source.compression;

    switch (source.compression) {
        .gzip => {
            decoder_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
            context.decoder_buffer = decoder_buffer;
            context.decoder = .{ .gzip = std.compress.flate.Decompress.init(&context.file_reader.interface, .gzip, decoder_buffer) };
            context.reader = &context.decoder.gzip.reader;
        },
        .xz => {
            context.decoder = .{ .xz = std.compress.xz.Decompress.init(&context.file_reader.interface, allocator, &.{}) catch return error.InvalidCompressedImage };
            context.reader = &context.decoder.xz.reader;
        },
        .zstd => {
            decoder_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
            context.decoder_buffer = decoder_buffer;
            context.decoder = .{ .zstd = std.compress.zstd.Decompress.init(&context.file_reader.interface, decoder_buffer, .{}) };
            context.reader = &context.decoder.zstd.reader;
        },
        else => return error.UnsupportedCompression,
    }

    return .{
        .reader = context.reader,
        .max_image_size = source.max_image_size,
        .context = context,
        .deinit_fn = DecodedStreamContext.destroy,
        .translate_errors = true,
    };
}

fn openBzip2Stream(source: *PathContext, io: std.Io, allocator: std.mem.Allocator) !Stream {
    const stdout_limit: std.Io.Limit = if (source.max_image_size) |limit| blk: {
        const limit_plus_one = std.math.add(u64, limit, 1) catch return error.DecompressedImageTooLarge;
        break :blk if (std.math.cast(usize, limit_plus_one)) |value| .limited(value) else .unlimited;
    } else .unlimited;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bzip2", "-dc", source.path },
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.DecompressedImageTooLarge,
        else => return error.InvalidCompressedImage,
    };
    defer allocator.free(result.stderr);
    if (source.max_image_size) |limit| {
        if (result.stdout.len > limit) {
            allocator.free(result.stdout);
            return error.DecompressedImageTooLarge;
        }
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.InvalidCompressedImage;
        },
        else => {
            allocator.free(result.stdout);
            return error.InvalidCompressedImage;
        },
    }

    const context = try allocator.create(EagerStreamContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .decoded = result.stdout,
        .reader = std.Io.Reader.fixed(result.stdout),
        .allocator = allocator,
    };
    return .{
        .reader = &context.reader,
        .max_image_size = source.max_image_size,
        .context = context,
        .deinit_fn = EagerStreamContext.destroy,
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
