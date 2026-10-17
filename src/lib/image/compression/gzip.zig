const std = @import("std");

const codec_api = @import("codec.zig");

const Decompress = std.compress.flate.Decompress;

const GzipContext = struct {
    window: []u8,
    decoder: *Decompress,

    fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *GzipContext = @ptrCast(@alignCast(context));
        allocator.destroy(self.decoder);
        allocator.free(self.window);
        allocator.destroy(self);
    }
};

pub fn open(args: codec_api.OpenArgs) !codec_api.Opened {
    const context = try args.allocator.create(GzipContext);
    errdefer args.allocator.destroy(context);

    context.window = try args.allocator.alloc(u8, std.compress.flate.max_window_len);
    errdefer args.allocator.free(context.window);

    const decoder = try args.allocator.create(Decompress);
    errdefer args.allocator.destroy(decoder);
    decoder.* = Decompress.init(args.encoded_reader, .gzip, context.window);
    context.decoder = decoder;

    return .{
        .reader = &decoder.reader,
        .translate_errors = true,
        .context = context,
        .deinit_fn = GzipContext.deinit,
    };
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .gzip;
pub const magic: []const u8 = &.{ 0x1f, 0x8b };
