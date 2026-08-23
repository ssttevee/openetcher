const std = @import("std");

const codec_api = @import("codec.zig");

const Decompress = std.compress.xz.Decompress;

fn open(args: codec_api.OpenArgs) anyerror!codec_api.Opened {
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

pub const codec: codec_api.Codec = .{
    .id = .xz,
    .magic = &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 },
    .open = open,
};
