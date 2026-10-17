//! Shared target-I/O backends.
//!
//! Each platform selects one namespace here as `target_io` at compile time.
//! `posix` serves regular files plus POSIX raw devices with kernel-alignment
//! handling; macOS and Linux use it. A future Windows backend adds its own
//! namespace with Win32 semantics.
//!
//! Every transfer is positional I/O through the caller's `std.Io`. It then
//! runs under any `Io` implementation, blocking or evented; it is a
//! cancelation point; tests can inject faults by wrapping the `Io`; and each
//! write carries its own offset, so writes to disjoint chunks can be in
//! flight together instead of contending for one file position.

const std = @import("std");

const device = @import("../../device.zig");

fn syncFile(io: std.Io, target: *device.OpenTarget) !void {
    try target.file.sync(io);
}

/// Writes all of `bytes` at `offset`. Unlike `File.writePositionalAll`, a
/// write that makes no progress fails rather than retrying forever, and a
/// partial write that ends off `alignment` fails rather than issuing a
/// follow-up write the kernel would reject.
fn writeAllAt(io: std.Io, file: std.Io.File, bytes: []const u8, offset: u64, alignment: usize) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const written = try file.writePositional(io, &.{bytes[index..]}, offset + index);
        if (written == 0) return error.ShortWrite;
        index += written;
        if (index < bytes.len and index % alignment != 0) return error.ShortWrite;
    }
}

/// Reads into `buffer` from `offset` until it is full or the target ends,
/// failing on a partial read that ends off `alignment` for the same reason
/// as `writeAllAt`.
fn readAllAt(io: std.Io, file: std.Io.File, buffer: []u8, offset: u64, alignment: usize) !usize {
    var index: usize = 0;
    while (index < buffer.len) {
        const count = try file.readPositional(io, &.{buffer[index..]}, offset + index);
        if (count == 0) break;
        index += count;
        if (index < buffer.len and index % alignment != 0) return error.InvalidDeviceRead;
    }
    return index;
}

/// Reads a possibly unaligned span from a raw device by rounding the request
/// out to alignment boundaries inside `scratch` and copying the interior.
/// `scratch` must hold `readScratchLength(buffer.len)` bytes.
pub fn readAlignedDeviceChunk(io: std.Io, target: *device.OpenTarget, buffer: []u8, offset: u64, scratch: []u8) !usize {
    if (buffer.len == 0) return 0;
    if (scratch.len < try target.info.capabilities.readScratchLength(buffer.len)) return error.ScratchBufferTooSmall;
    const alignment: usize = target.info.capabilities.read_alignment;

    const aligned_offset = std.mem.alignBackward(u64, offset, alignment);
    const prefix: usize = @intCast(offset - aligned_offset);
    const aligned_len = std.mem.alignForward(usize, prefix + buffer.len, alignment);
    const start = std.mem.alignPointerOffset(scratch.ptr, alignment).?;
    const aligned_buffer = scratch[start..][0..aligned_len];

    const read_count = try readAllAt(io, target.file, aligned_buffer, aligned_offset, alignment);
    if (read_count <= prefix) return 0;
    const available = @min(buffer.len, read_count - prefix);
    @memcpy(buffer[0..available], aligned_buffer[prefix..][0..available]);
    return available;
}

/// Writes `buffer[0..len]` to a raw device at an aligned `offset`. A partial
/// final block is zero-padded in place, so `buffer` must hold
/// `writeBufferLength(len)` bytes; the bytes past `len` are overwritten.
pub fn writeAlignedDeviceChunk(io: std.Io, target: *device.OpenTarget, buffer: []u8, len: usize, offset: u64) !void {
    const alignment: usize = target.info.capabilities.write_alignment;
    // The kernel rejects a misaligned offset with EINVAL, which `std.Io`
    // treats as a caller bug; report it as the plan problem it is.
    if (!target.info.capabilities.isWriteAligned(offset)) return error.UnalignedTargetOffset;
    const padded_len = std.mem.alignForward(usize, len, alignment);
    if (buffer.len < padded_len) return error.ScratchBufferTooSmall;
    @memset(buffer[len..padded_len], 0);

    try writeAllAt(io, target.file, buffer[0..padded_len], offset, alignment);
}

/// Backend used by macOS and Linux: positional I/O for files,
/// alignment-aware positional I/O for raw devices.
pub const posix = struct {
    pub const supports_devices = true;

    /// Writes `buffer[0..len]` at `offset`; see `writeAlignedDeviceChunk`
    /// for how devices use the rest of `buffer`.
    pub fn writeAt(io: std.Io, target: *device.OpenTarget, buffer: []u8, len: usize, offset: u64) !void {
        if (!target.info.capabilities.isDevice()) return writeAllAt(io, target.file, buffer[0..len], offset, 1);
        return writeAlignedDeviceChunk(io, target, buffer, len, offset);
    }

    pub fn readAt(io: std.Io, target: *device.OpenTarget, buffer: []u8, offset: u64, scratch: []u8) !usize {
        if (!target.info.capabilities.isDevice()) return target.file.readPositionalAll(io, buffer, offset);
        return readAlignedDeviceChunk(io, target, buffer, offset, scratch);
    }

    pub fn sync(io: std.Io, target: *device.OpenTarget) !void {
        return syncFile(io, target);
    }
};

/// Backend used by platforms without raw-device support yet.
pub const positional_only = struct {
    pub const supports_devices = false;

    pub fn writeAt(io: std.Io, target: *device.OpenTarget, buffer: []u8, len: usize, offset: u64) !void {
        if (target.info.capabilities.isDevice()) return error.UnsupportedTargetType;
        return writeAllAt(io, target.file, buffer[0..len], offset, 1);
    }

    pub fn readAt(io: std.Io, target: *device.OpenTarget, buffer: []u8, offset: u64, scratch: []u8) !usize {
        _ = scratch;
        if (target.info.capabilities.isDevice()) return error.UnsupportedTargetType;
        return target.file.readPositionalAll(io, buffer, offset);
    }

    pub fn sync(io: std.Io, target: *device.OpenTarget) !void {
        return syncFile(io, target);
    }
};
