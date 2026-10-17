const std = @import("std");

const codec_api = @import("codec.zig");

const Decompress = std.compress.zstd.Decompress;

const ZstdContext = struct {
    window: []u8,
    decoder: *Decompress,

    fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *ZstdContext = @ptrCast(@alignCast(context));
        allocator.destroy(self.decoder);
        allocator.free(self.window);
        allocator.destroy(self);
    }
};

pub fn open(args: codec_api.OpenArgs) !codec_api.Opened {
    const context = try args.allocator.create(ZstdContext);
    errdefer args.allocator.destroy(context);

    context.window = try args.allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    errdefer args.allocator.free(context.window);

    const decoder = try args.allocator.create(Decompress);
    errdefer args.allocator.destroy(decoder);
    decoder.* = Decompress.init(args.encoded_reader, context.window, .{});
    context.decoder = decoder;

    return .{
        .reader = &decoder.reader,
        .translate_errors = true,
        .context = context,
        .deinit_fn = ZstdContext.deinit,
    };
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .zstd;
pub const magic: []const u8 = &.{ 0x28, 0xb5, 0x2f, 0xfd };
