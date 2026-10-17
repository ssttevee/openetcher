//! Test-only `std.Io` that delegates every operation to another `Io` but
//! fails, shortens, or stalls chosen positional transfers, and can withhold
//! concurrency. Target I/O goes through `std.Io`, so tests drive the flash
//! engine's error, cancelation, and fallback paths with this instead of
//! failing hardware or a single-threaded build.

const std = @import("std");

const FaultIo = @This();

inner: std.Io,
faults: []const Fault,
/// Makes `concurrent` fail with `error.ConcurrencyUnavailable` and `async`
/// run its function before returning, as a single-threaded `Io` does.
serial: bool = false,
/// Transfers that have begun to stall.
stalled: std.atomic.Value(u32) = .init(0),
/// Stalled transfers that ended because they were canceled.
canceled: std.atomic.Value(u32) = .init(0),

pub const Fault = struct {
    op: Op,
    /// The fault applies to every transfer of `op` whose span contains this
    /// byte offset.
    offset: u64,
    effect: Effect,

    pub const Op = enum { write, read };

    pub const Effect = union(enum) {
        /// Fails with `error.InputOutput`, as a dying device does.
        input_output,
        /// Transfers at most this many bytes.
        short: usize,
        /// Blocks until canceled, as a hung device does. Gives up after
        /// `stall_limit` with `error.InputOutput`, so a cancelation that never
        /// arrives fails the test instead of hanging it.
        stall,
    };
};

pub const stall_limit: std.Io.Duration = .fromSeconds(30);

pub fn init(inner: std.Io, faults: []const Fault) FaultIo {
    return .{ .inner = inner, .faults = faults };
}

pub fn io(self: *FaultIo) std.Io {
    return .{ .userdata = self, .vtable = &vtable };
}

fn fromUserdata(userdata: ?*anyopaque) *FaultIo {
    return @ptrCast(@alignCast(userdata));
}

const vtable: std.Io.VTable = table: {
    var table: std.Io.VTable = undefined;
    for (@typeInfo(std.Io.VTable).@"struct".field_names) |name| @field(table, name) = forward(name);
    table.async = async;
    table.concurrent = concurrent;
    table.fileWritePositional = fileWritePositional;
    table.fileReadPositional = fileReadPositional;
    break :table table;
};

/// A vtable entry that calls the inner `Io`'s entry of the same name with
/// the inner userdata, whatever its parameters.
fn forward(comptime name: []const u8) @FieldType(std.Io.VTable, name) {
    const Function = @typeInfo(@FieldType(std.Io.VTable, name)).pointer.child;
    const info = @typeInfo(Function).@"fn";
    const R = info.return_type.?;
    const P = info.param_types;
    const Inner = struct {
        fn get(userdata: ?*anyopaque) std.Io {
            return fromUserdata(userdata).inner;
        }
    };
    return switch (P.len) {
        1 => &struct {
            fn call(userdata: ?*anyopaque) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata);
            }
        }.call,
        2 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a);
            }
        }.call,
        3 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?, b: P[2].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a, b);
            }
        }.call,
        4 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a, b, c);
            }
        }.call,
        5 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a, b, c, d);
            }
        }.call,
        6 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a, b, c, d, e);
            }
        }.call,
        7 => &struct {
            fn call(userdata: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?, f: P[6].?) R {
                const inner = Inner.get(userdata);
                return @field(inner.vtable, name)(inner.userdata, a, b, c, d, e, f);
            }
        }.call,
        else => @compileError("FaultIo cannot forward std.Io.VTable." ++ name ++ "; add a case for its parameter count"),
    };
}

fn find(self: *const FaultIo, op: Fault.Op, offset: u64, len: usize) ?Fault.Effect {
    for (self.faults) |fault| {
        if (fault.op == op and fault.offset >= offset and fault.offset - offset < len) return fault.effect;
    }
    return null;
}

/// Applies `effect` to a transfer of `len` bytes: returns the length to
/// transfer, or the error to report instead.
fn apply(self: *FaultIo, effect: Fault.Effect, len: usize) error{ InputOutput, Canceled }!usize {
    switch (effect) {
        .input_output => return error.InputOutput,
        .short => |limit| return @min(len, limit),
        .stall => {
            _ = self.stalled.fetchAdd(1, .monotonic);
            self.inner.sleep(stall_limit, .awake) catch |err| switch (err) {
                error.Canceled => {
                    _ = self.canceled.fetchAdd(1, .monotonic);
                    return error.Canceled;
                },
            };
            return error.InputOutput;
        },
    }
}

fn async(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*std.Io.AnyFuture {
    const self = fromUserdata(userdata);
    if (self.serial) return std.Io.noAsync(null, result, result_alignment, context, context_alignment, start);
    return self.inner.vtable.async(self.inner.userdata, result, result_alignment, context, context_alignment, start);
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    const self = fromUserdata(userdata);
    if (self.serial) return error.ConcurrencyUnavailable;
    return self.inner.vtable.concurrent(self.inner.userdata, result_len, result_alignment, context, context_alignment, start);
}

fn fileWritePositional(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    const self = fromUserdata(userdata);
    const inner = self.inner;
    // Faults apply to single-buffer writes, the only kind the target
    // backends issue.
    const simple = header.len == 0 and data.len == 1 and splat == 1;
    const effect = (if (simple) self.find(.write, offset, data[0].len) else null) orelse
        return inner.vtable.fileWritePositional(inner.userdata, file, header, data, splat, offset);
    const len = try self.apply(effect, data[0].len);
    if (len == 0) return 0;
    return inner.vtable.fileWritePositional(inner.userdata, file, header, &.{data[0][0..len]}, splat, offset);
}

fn fileReadPositional(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    const self = fromUserdata(userdata);
    const inner = self.inner;
    const effect = (if (data.len == 1) self.find(.read, offset, data[0].len) else null) orelse
        return inner.vtable.fileReadPositional(inner.userdata, file, data, offset);
    const len = try self.apply(effect, data[0].len);
    if (len == 0) return 0;
    return inner.vtable.fileReadPositional(inner.userdata, file, &.{data[0][0..len]}, offset);
}

test "faults hit only the chosen transfers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault_io: FaultIo = .init(std.testing.io, &.{
        .{ .op = .write, .offset = 100, .effect = .input_output },
        .{ .op = .read, .offset = 8, .effect = .{ .short = 3 } },
    });
    const io_ = fault_io.io();

    var file = try tmp.dir.createFile(io_, "file", .{ .read = true });
    defer file.close(io_);
    try file.writePositionalAll(io_, "0123456789", 0);
    try std.testing.expectError(error.InputOutput, file.writePositionalAll(io_, "x", 100));

    var buffer: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositional(io_, &.{&buffer}, 5));
    try std.testing.expectEqualStrings("567", buffer[0..3]);
    try std.testing.expectEqual(@as(usize, 1), try file.readPositional(io_, &.{&buffer}, 9));
}
