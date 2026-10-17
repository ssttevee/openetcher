const std = @import("std");

const codec_api = @import("codec.zig");

const Decompress = std.compress.xz.Decompress;

pub fn open(args: codec_api.OpenArgs) !codec_api.Opened {
    const decoder = try args.allocator.create(Decompress);
    errdefer args.allocator.destroy(decoder);

    decoder.* = Decompress.init(args.encoded_reader, args.allocator, &.{}) catch {
        return error.InvalidCompressedImage;
    };

    return .{
        .reader = &decoder.reader,
        .translate_errors = true,
        .context = decoder,
        .deinit_fn = deinit,
    };
}

fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
    const decoder: *Decompress = @ptrCast(@alignCast(context));
    decoder.deinit();
    allocator.destroy(decoder);
}

// Codec contract; see codec.zig.

pub const id: codec_api.Compression = .xz;
pub const magic: []const u8 = &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 };
