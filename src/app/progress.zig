//! Reads the library's `std.Progress` nodes from inside this process.
//!
//! The library reports progress only through `std.Progress`, which keeps
//! its counters private and draws them on a terminal, or, when the process
//! has a progress parent, serializes the whole node tree into a pipe every
//! refresh. The README's way for a GUI to get progress is to decode those
//! packets, and nothing requires the reader to be another process: `start`
//! hands `std.Progress` an `Io` whose `progressParentFile` is a pipe we
//! read ourselves.
//!
//! The packet format is `std.Progress`'s own: a node count `n`, then `n`
//! node records (completed `u32` and estimated total `u32`, little endian,
//! then a 120-byte zero-padded name), then `n` parent indices (`u8`, with
//! 255 for the root). It is shared by every Zig process that reports
//! progress to a parent, such as `zig build`'s children, and is checked by
//! the tests below against the size `std.Progress` declares.
const std = @import("std");
const Io = std.Io;

/// Bytes per count in every node the library reports.
pub const unit_bytes = 1024;

const name_len = std.Progress.Node.max_name_len;
const record_len = 8 + name_len;
const max_nodes = 255;

comptime {
    // a full packet of the largest tree must fit what std.Progress sends
    std.debug.assert(1 + (std.Progress.max_packet_len - 1) / (record_len + 1) * (record_len + 1) <= std.Progress.max_packet_len);
}

/// One node of a decoded packet.
pub const Node = struct {
    name: []const u8,
    completed: u32,
    /// Zero while unknown.
    total: u32,
    /// Index of the parent node; null for the root.
    parent: ?u8,
};

/// A decoded tree of nodes, borrowing the packet it was decoded from.
pub const Tree = struct {
    nodes: []const Node,

    /// Whether `nodes[index]` is `ancestor` or below it.
    pub fn isUnder(self: Tree, index: usize, ancestor: usize) bool {
        var current: ?usize = index;
        var steps: usize = 0;
        while (current) |i| : (steps += 1) {
            if (i == ancestor) return true;
            // a malformed packet can't loop forever
            if (i >= self.nodes.len or steps > self.nodes.len) return false;
            current = if (self.nodes[i].parent) |parent| parent else null;
        }
        return false;
    }

    /// The first node named `name`.
    pub fn find(self: Tree, name: []const u8) ?usize {
        for (self.nodes, 0..) |node, index| {
            if (std.mem.eql(u8, node.name, name)) return index;
        }
        return null;
    }

    /// The first node named `name` below the node named `task`.
    pub fn findUnder(self: Tree, task: []const u8, name: []const u8) ?Node {
        const task_index = self.find(task) orelse return null;
        for (self.nodes, 0..) |node, index| {
            if (index != task_index and std.mem.eql(u8, node.name, name) and self.isUnder(index, task_index)) return node;
        }
        return null;
    }
};

/// Decodes a packet body: `count` records followed by `count` parents.
pub fn decode(body: []const u8, count: usize, nodes: []Node) error{InvalidPacket}!Tree {
    if (body.len != count * (record_len + 1) or count > nodes.len) return error.InvalidPacket;
    const parents = body[count * record_len ..];
    for (nodes[0..count], 0..) |*node, index| {
        const record = body[index * record_len ..][0..record_len];
        const name = record[8..];
        node.* = .{
            .completed = std.mem.readInt(u32, record[0..4], .little),
            .total = std.mem.readInt(u32, record[4..8], .little),
            .name = name[0 .. std.mem.indexOfScalar(u8, name, 0) orelse name.len],
            .parent = switch (parents[index]) {
                // 255 is the root's parent; 254 marks unused storage, never sent
                255, 254 => null,
                else => |parent| if (parent < count) parent else return error.InvalidPacket,
            },
        };
        // a node another process forwards to us; its counts mean nothing here
        if (node.total == std.math.maxInt(u32)) node.* = .{ .name = "", .completed = 0, .total = 0, .parent = node.parent };
    }
    return .{ .nodes = nodes[0..count] };
}

/// Starts `std.Progress` with a pipe for its output, and reads the pipe on
/// a task of its own, calling `on_tree` with every packet.
///
/// `std.Progress` can only be started once per process, so there is one
/// monitor for the app's lifetime. It must not move after `start`.
pub const Monitor = struct {
    io: Io,
    /// The real `Io`'s functions, except `progressParentFile`. Lives as
    /// long as `std.Progress`, which keeps the `Io` it was started with.
    vtable: Io.VTable,
    read_end: Io.File,
    write_end: Io.File,
    root: std.Progress.Node,
    reader: Io.Group = .init,
    context: *anyopaque,
    on_tree: *const fn (context: *anyopaque, tree: Tree) void,

    /// `progressParentFile` gets only the real `Io`'s userdata, so the pipe
    /// it returns is global, as `std.Progress` itself is.
    var parent_file: ?Io.File = null;

    pub fn start(self: *Monitor, io: Io, context: *anyopaque, on_tree: *const fn (context: *anyopaque, tree: Tree) void) !void {
        const fds = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
        self.* = .{
            .io = io,
            .vtable = io.vtable.*,
            .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            .root = .none,
            .context = context,
            .on_tree = on_tree,
        };
        errdefer {
            self.read_end.close(io);
            self.write_end.close(io);
        }

        std.debug.assert(parent_file == null);
        parent_file = self.write_end;
        self.vtable.progressParentFile = progressParentFile;
        const progress_io: Io = .{ .userdata = io.userdata, .vtable = &self.vtable };

        try self.reader.concurrent(io, readPackets, .{ self, io });
        self.root = std.Progress.start(progress_io, .{
            .refresh_rate_ns = .fromMilliseconds(100),
            .initial_delay_ns = .fromMilliseconds(0),
        });
    }

    /// Ends progress reporting and the reader. Nothing may report progress
    /// any more.
    pub fn stop(self: *Monitor) void {
        self.root.end();
        self.write_end.close(self.io);
        self.reader.cancel(self.io);
        self.read_end.close(self.io);
        parent_file = null;
    }

    fn progressParentFile(_: ?*anyopaque) std.Progress.ParentFileError!Io.File {
        return parent_file orelse error.EnvironmentVariableMissing;
    }

    fn readPackets(self: *Monitor, io: Io) Io.Cancelable!void {
        var buffer: [4096]u8 = undefined;
        var file_reader = self.read_end.readerStreaming(io, &buffer);
        const reader = &file_reader.interface;
        var body: [max_nodes * (record_len + 1)]u8 = undefined;
        var nodes: [max_nodes]Node = undefined;
        while (true) {
            const count = reader.takeByte() catch return;
            const len = @as(usize, count) * (record_len + 1);
            reader.readSliceAll(body[0..len]) catch return;
            const tree = decode(body[0..len], count, &nodes) catch continue;
            self.on_tree(self.context, tree);
        }
    }
};

/// Builds a packet the way `std.Progress` serializes one, for tests.
fn testPacket(buffer: []u8, nodes: []const Node) []const u8 {
    buffer[0] = @intCast(nodes.len);
    for (nodes, 0..) |node, index| {
        const record = buffer[1 + index * record_len ..][0..record_len];
        std.mem.writeInt(u32, record[0..4], node.completed, .little);
        std.mem.writeInt(u32, record[4..8], node.total, .little);
        @memset(record[8..], 0);
        @memcpy(record[8..][0..node.name.len], node.name);
        buffer[1 + nodes.len * record_len + index] = node.parent orelse 255;
    }
    return buffer[0 .. 1 + nodes.len * (record_len + 1)];
}

test "record size matches std.Progress storage" {
    // std.Progress sends its node storage as is: two u32s and the name
    try std.testing.expectEqual(record_len, 4 + 4 + std.Progress.Node.max_name_len);
}

test "decode finds a task's nodes by name" {
    var buffer: [4096]u8 = undefined;
    const packet = testPacket(&buffer, &.{
        .{ .name = "", .completed = 0, .total = 0, .parent = null },
        .{ .name = "load", .completed = 0, .total = 0, .parent = 0 },
        .{ .name = "compressed KiB decoded", .completed = 10, .total = 40, .parent = 1 },
        .{ .name = "flash", .completed = 0, .total = 0, .parent = 0 },
        .{ .name = "KiB written", .completed = 300, .total = 1200, .parent = 3 },
    });

    var nodes: [8]Node = undefined;
    const tree = try decode(packet[1..], packet[0], &nodes);
    try std.testing.expectEqual(5, tree.nodes.len);

    const written = tree.findUnder("flash", "KiB written").?;
    try std.testing.expectEqual(300, written.completed);
    try std.testing.expectEqual(1200, written.total);
    // the decoding node belongs to the other task
    try std.testing.expectEqual(null, tree.findUnder("flash", "compressed KiB decoded"));
    try std.testing.expectEqual(10, tree.findUnder("load", "compressed KiB decoded").?.completed);

    try std.testing.expectError(error.InvalidPacket, decode(packet[1 .. packet.len - 1], packet[0], &nodes));
}
