const std = @import("std");

const codec_api = @import("codec.zig");

/// bzip2 has no in-tree decoder, so this codec shells out to the `bzip2`
/// executable and materializes the whole decoded image in memory. The
/// behavior matches the historical implementation; a native streaming
/// decoder can replace `open` without touching callers.
const EagerContext = struct {
    decoded: []u8,
    reader: std.Io.Reader,

    fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
        const self: *EagerContext = @ptrCast(@alignCast(context));
        allocator.free(self.decoded);
        allocator.destroy(self);
    }
};

fn open(args: codec_api.OpenArgs) anyerror!codec_api.Opened {
    const stdout_limit: std.Io.Limit = if (args.max_image_size) |limit| blk: {
        const limit_plus_one = std.math.add(u64, limit, 1) catch return error.DecompressedImageTooLarge;
        break :blk if (std.math.cast(usize, limit_plus_one)) |value| .limited(value) else .unlimited;
    } else .unlimited;

    const result = std.process.run(args.allocator, args.io, .{
        .argv = &.{ "bzip2", "-dc", args.path },
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.DecompressedImageTooLarge,
        else => return error.InvalidCompressedImage,
    };
    defer args.allocator.free(result.stderr);

    if (args.max_image_size) |limit| {
        if (result.stdout.len > limit) {
            args.allocator.free(result.stdout);
            return error.DecompressedImageTooLarge;
        }
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            args.allocator.free(result.stdout);
            return error.InvalidCompressedImage;
        },
        else => {
            args.allocator.free(result.stdout);
            return error.InvalidCompressedImage;
        },
    }

    const context = try args.allocator.create(EagerContext);
    errdefer args.allocator.destroy(context);
    context.* = .{
        .decoded = result.stdout,
        .reader = std.Io.Reader.fixed(result.stdout),
    };

    return .{
        .reader = &context.reader,
        .translate_errors = false,
        .context = context,
        .deinit_fn = EagerContext.deinit,
    };
}

pub const codec: codec_api.Codec = .{
    .id = .bzip2,
    .magic = "BZh",
    .open = open,
};
