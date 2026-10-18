//! The OpenEtcher interface: fabrum.app components over a plain model.
//!
//! Nothing here touches the window, the renderer or the disk. The shell in
//! `main.zig` provides `model.Services` and `model.Icons` to the runtime as
//! root values; the tests below provide fakes and drive the interface by
//! clicking, as a user would.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;

pub const model = @import("ui/model.zig");
pub const theme = @import("ui/theme.zig");
pub const format = @import("ui/format.zig");
pub const App = @import("ui/App.zig");
pub const DriveSelector = @import("ui/DriveSelector.zig");

test {
    _ = format;
    _ = model;
}

const testing = std.testing;
const TestRuntime = app.Runtime(.{});

/// Records what the interface asked for, so tests can answer as the real
/// services would.
const FakeServices = struct {
    picked: ?app.Handler(?[]u8) = null,
    loads: std.ArrayList(struct { id: u32, path: []const u8 }) = .empty,
    loaded: ?model.ImageHandlers = null,
    unloads: usize = 0,
    listed: ?app.Handler(model.DriveListing) = null,
    lists: usize = 0,
    flash: ?model.FlashHandlers = null,
    flash_target: ?[]const u8 = null,
    cancels: usize = 0,

    fn deinit(self: *FakeServices) void {
        for (self.loads.items) |load| testing.allocator.free(load.path);
        self.loads.deinit(testing.allocator);
        if (self.flash_target) |path| testing.allocator.free(path);
    }

    fn services(self: *FakeServices) model.Services {
        return .{ .ctx = self, .vtable = &.{
            .pickImage = pickImage,
            .loadImage = loadImage,
            .unloadImage = unloadImage,
            .listDrives = listDrives,
            .startFlash = startFlash,
            .cancelFlash = cancelFlash,
        } };
    }

    fn get(ctx: *anyopaque) *FakeServices {
        return @ptrCast(@alignCast(ctx));
    }

    fn pickImage(ctx: *anyopaque, on_picked: app.Handler(?[]u8)) void {
        get(ctx).picked = on_picked;
    }

    fn loadImage(ctx: *anyopaque, id: u32, path: []const u8, handlers: model.ImageHandlers) void {
        const self = get(ctx);
        self.loads.append(testing.allocator, .{ .id = id, .path = testing.allocator.dupe(u8, path) catch unreachable }) catch unreachable;
        self.loaded = handlers;
    }

    fn unloadImage(ctx: *anyopaque) void {
        get(ctx).unloads += 1;
    }

    fn listDrives(ctx: *anyopaque, on_listed: app.Handler(model.DriveListing)) void {
        get(ctx).listed = on_listed;
        get(ctx).lists += 1;
    }

    fn startFlash(ctx: *anyopaque, image_id: u32, target: *const model.Drive, handlers: model.FlashHandlers) void {
        _ = image_id;
        const self = get(ctx);
        self.flash = handlers;
        self.flash_target = testing.allocator.dupe(u8, target.path) catch unreachable;
    }

    fn cancelFlash(ctx: *anyopaque) void {
        get(ctx).cancels += 1;
    }
};

/// Icons as plain squares that fill their box.
const fake_icons: model.Icons = .{ .ctx = undefined, .make = struct {
    var square: layout.Content = .{ .vtable = &.{ .measure = measure } };

    fn make(_: *anyopaque, _: std.mem.Allocator, _: model.Icon, _: fabrum.Color) std.mem.Allocator.Error!*layout.Content {
        return &square;
    }

    fn measure(_: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!fabrum.Vec2 {
        const side = @min(constraints.max_width orelse 16, constraints.max_height orelse 16);
        return .init(side, side);
    }
}.make };

const Harness = struct {
    rt: TestRuntime,
    fake: FakeServices = .{},
    services: model.Services = undefined,

    /// Must not move after `init`.
    fn init(self: *Harness) !void {
        self.* = .{ .rt = try .init(testing.allocator, .{
            .io = testing.io,
            .provide = &.{ .of(&self.services), .of(&fake_icons) },
        }) };
        self.services = self.fake.services();
        try self.frame();
    }

    fn deinit(self: *Harness) void {
        self.rt.deinit();
        self.fake.deinit();
    }

    fn frame(self: *Harness) !void {
        _ = try self.rt.frame(App, .{}, .init(800, 480));
    }

    fn state(self: *Harness) *App.State {
        return self.rt.rootState(App).?;
    }

    fn findText(self: *Harness, text: []const u8) ?*const layout.Unit {
        for (self.rt.context().units.items) |*unit| {
            if (unit.data != .content) continue;
            const t = TestRuntime.Text.asTextContent(unit.data.content) orelse continue;
            if (std.mem.eql(u8, t.text, text)) return unit;
        }
        return null;
    }

    fn has(self: *Harness, text: []const u8) bool {
        return self.findText(text) != null;
    }

    /// Clicks the middle of the text `label`, then runs a frame.
    fn click(self: *Harness, label: []const u8) !void {
        const unit = self.findText(label) orelse {
            std.debug.print("no text \"{s}\" on screen\n", .{label});
            return error.NoSuchText;
        };
        const point: fabrum.Vec2 = .init(unit.bbox.x + unit.bbox.w / 2, unit.bbox.y + unit.bbox.h / 2);
        var buttons: app.MouseEvent.Buttons = .empty;
        buttons.set(app.MouseEvent.primary);
        try self.rt.mouse(.{ .position = point, .pressed = buttons });
        try self.rt.mouse(.{ .position = point });
        try self.frame();
    }

    fn post(self: *Harness, handler: anytype, payload: anytype) !void {
        try self.rt.post(handler, payload);
        try self.frame();
    }

    fn pickImage(self: *Harness, path: []const u8, size: u64) !void {
        try self.click("Flash from file");
        try self.post(self.fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, path)));
        const id = self.fake.loads.getLast().id;
        try self.post(self.fake.loaded.?.loaded, model.ImageLoad{ .id = id, .result = .{ .ready = .{ .size = size, .file_size = size, .layout = "mbr" } } });
    }

    fn listDrives(self: *Harness, drives: []const model.Drive) !void {
        const items = try testing.allocator.alloc(model.Drive, drives.len);
        for (drives, items) |drive, *item| item.* = try drive.clone(testing.allocator);
        try self.post(self.fake.listed.?, model.DriveListing{ .listed = .{ .items = items } });
    }
};

const sd_card: model.Drive = .{ .path = "/dev/disk4", .name = "SD Card Reader", .location = "/dev/disk4", .size = 31_914_983_424, .system = false, .removable = true };
const internal: model.Drive = .{ .path = "/dev/disk0", .name = "APPLE SSD", .location = "/dev/disk0", .size = 500_000_000_000, .system = true, .removable = false };
const tiny: model.Drive = .{ .path = "/dev/disk5", .name = "Tiny Stick", .location = "/dev/disk5", .size = 1_000_000, .system = false, .removable = true };
const file_target: model.Drive = .{ .path = "/tmp/target.img", .name = "target.img", .location = "/tmp/target.img", .size = 64 << 20, .system = false, .removable = false, .file = true };

test "choosing an image loads it and enables the target step" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try testing.expect(h.has("Flash from file"));
    try testing.expect(h.has("Select target"));
    // nothing to write yet: the target and flash buttons are disabled
    try h.click("Select target");
    try testing.expectEqual(0, h.fake.lists);

    try h.click("Flash from file");
    try h.post(h.fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/raspios.img.xz")));
    try testing.expectEqual(1, h.fake.loads.items.len);
    try testing.expectEqualStrings("/images/raspios.img.xz", h.fake.loads.items[0].path);
    try testing.expect(h.has("raspios.img.xz"));
    try testing.expect(h.has("Reading image\u{2026}"));
    try h.post(h.fake.loaded.?.progress, model.ImageProgress{ .id = h.fake.loads.items[0].id, .loading = .{ .decoded = 125, .total = 500 } });
    try testing.expect(h.has("Decompressing\u{2026} 25%"));

    try h.post(h.fake.loaded.?.loaded, model.ImageLoad{ .id = h.fake.loads.items[0].id, .result = .{ .ready = .{
        .size = 2_700_000_000,
        .file_size = 500_000_000,
        .compression = "xz",
        .layout = "mbr",
    } } });
    try testing.expect(h.has("2.70 GB \u{00b7} xz"));

    try h.click("Select target");
    try testing.expectEqual(1, h.fake.lists);
    try testing.expect(h.has("Looking for drives\u{2026}"));
}

test "canceling the file picker or a stale load changes nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.click("Flash from file");
    try h.post(h.fake.picked.?, @as(?[]u8, null));
    try testing.expectEqual(null, h.state().image);

    try h.click("Flash from file");
    try h.post(h.fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/first.img")));
    try h.click("Remove");
    try testing.expectEqual(1, h.fake.unloads);
    try h.click("Flash from file");
    try h.post(h.fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/second.iso")));
    // the first image's result arrives after the second was chosen
    try h.post(h.fake.loaded.?.loaded, model.ImageLoad{ .id = h.fake.loads.items[0].id, .result = .{ .failed = error.InvalidImage } });
    try testing.expect(h.state().image.?.status == .loading);
    try testing.expect(h.has("second.iso"));

    try h.post(h.fake.loaded.?.loaded, model.ImageLoad{ .id = h.fake.loads.items[1].id, .result = .{ .failed = error.InvalidImage } });
    try testing.expect(h.has(model.describeError(error.InvalidImage)));

    try h.click("Remove");
    try testing.expectEqual(null, h.state().image);
    try testing.expectEqual(2, h.fake.unloads);
    try testing.expect(h.has("Flash from file"));
}

test "the drive selector hides system drives and refuses ones too small" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 2_000_000_000);
    try h.click("Select target");
    try h.listDrives(&.{ internal, sd_card, tiny });

    try testing.expect(h.has("SD Card Reader"));
    try testing.expect(!h.has("APPLE SSD"));
    try testing.expect(h.has("TOO SMALL"));

    // too small to pick, so Select stays disabled
    try h.click("Tiny Stick");
    try h.click("Select");
    try testing.expectEqual(null, h.state().target);
    try testing.expectEqual(App.State.Dialog.drives, h.state().dialog);

    try h.click("Show 1 hidden");
    try testing.expect(h.has("APPLE SSD"));
    try testing.expect(h.has("SYSTEM DRIVE"));
    try h.click("Hide 1 system drive");
    try testing.expect(!h.has("APPLE SSD"));

    try h.click("SD Card Reader");
    try h.click("Select");
    try testing.expectEqual(App.State.Dialog.none, h.state().dialog);
    try testing.expectEqualStrings("/dev/disk4", h.state().target.?.path);
    try testing.expect(h.has("31.9 GB"));
    try testing.expect(h.has("Change"));

    // reopening starts from the current target, and Cancel keeps it
    try h.click("Change");
    try testing.expectEqual(2, h.fake.lists);
    try h.listDrives(&.{sd_card});
    try h.click("Cancel");
    try testing.expectEqualStrings("/dev/disk4", h.state().target.?.path);
}

test "flashing a drive asks first, reports progress and finishes" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 2_000_000_000);
    try h.click("Select target");
    try h.listDrives(&.{sd_card});
    try h.click("SD Card Reader");
    try h.click("Select");

    try h.click("Flash!");
    try testing.expect(h.has("Erase SD Card Reader?"));
    try testing.expectEqual(null, h.fake.flash);
    try h.click("Cancel");
    try testing.expectEqual(null, h.fake.flash);

    try h.click("Flash!");
    try h.click("Yes, flash it");
    try testing.expectEqualStrings("/dev/disk4", h.fake.flash_target.?);
    try testing.expect(h.has("Starting\u{2026}"));
    // nothing can change while flashing
    try testing.expect(!h.has("Remove"));
    try testing.expect(!h.has("Change"));

    const ms = std.time.ns_per_ms;
    const handlers = h.fake.flash.?;
    try h.post(handlers.progress, model.FlashProgress{ .phase = .flashing, .completed = 0, .total = 2_000_000_000, .at_ns = 1000 * ms });
    try h.post(handlers.progress, model.FlashProgress{ .phase = .flashing, .completed = 500_000_000, .total = 2_000_000_000, .at_ns = 2000 * ms });
    try testing.expect(h.has("Flashing\u{2026} 25%"));
    try testing.expect(h.has("500 MB/s \u{00b7} ETA 3s"));

    try h.post(handlers.progress, model.FlashProgress{ .phase = .verifying, .completed = 1_000_000_000, .total = 2_000_000_000, .at_ns = 6000 * ms });
    try testing.expect(h.has("Validating\u{2026} 50%"));

    try h.post(handlers.done, model.FlashOutcome{ .done = .{ .image_size = 2_000_000_000, .bytes_written = 2_000_000_000, .elapsed_ns = 8000 * ms } });
    try testing.expect(h.has("Flash Complete!"));
    try testing.expect(h.has("os.img was written to SD Card Reader and validated."));
    try testing.expect(h.has("Wrote 2.00 GB in 8s \u{00b7} 250 MB/s"));

    try h.click("Flash another");
    try testing.expectEqual(null, h.state().target);
    try testing.expect(h.state().image != null);
    try testing.expect(h.has("Select target"));
}

test "system drives get a stronger warning, file targets none" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 1000);
    try h.click("Select target");
    try h.listDrives(&.{ internal, file_target });
    try h.click("Show 1 hidden");
    try h.click("APPLE SSD");
    try h.click("Select");
    try testing.expect(h.has("System drive"));
    try h.click("Flash!");
    try testing.expect(h.has("This is a system drive. Writing to it can leave this Mac unable to start."));
    try h.click("Cancel");

    try h.click("Change");
    try h.listDrives(&.{ internal, file_target });
    try h.click("target.img");
    try h.click("Select");
    try h.click("Flash!");
    // straight to work
    try testing.expectEqualStrings("/tmp/target.img", h.fake.flash_target.?);
}

test "canceling a flash asks the services once and shows how it ended" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 1000);
    try h.click("Select target");
    try h.listDrives(&.{file_target});
    try h.click("target.img");
    try h.click("Select");
    try h.click("Flash!");

    try h.click("Cancel");
    try testing.expectEqual(1, h.fake.cancels);
    try testing.expect(h.has("Canceling\u{2026}"));
    try h.post(h.fake.flash.?.done, @as(model.FlashOutcome, .canceled));
    try testing.expect(h.has("Flash Canceled"));

    try h.click("Flash another");
    try h.click("Select target");
    try h.post(h.fake.listed.?, model.DriveListing{ .failed = error.DiskListFailed });
    try testing.expect(h.has("Listing drives failed."));
}

test "a failed flash shows why" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 1000);
    try h.click("Select target");
    try h.listDrives(&.{sd_card});
    try h.click("SD Card Reader");
    try h.click("Select");
    try h.click("Flash!");
    try h.click("Yes, flash it");
    try h.post(h.fake.flash.?.done, model.FlashOutcome{ .failed = error.AccessDenied });
    try testing.expect(h.has("Flash Failed"));
    try testing.expect(h.has(model.describeError(error.AccessDenied)));
}

test "a relisting that reorders the drives keeps the picked one" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.pickImage("/images/os.img", 1000);
    try h.click("Select target");
    try h.listDrives(&.{ sd_card, file_target });
    try h.click("target.img");

    // rows follow their drive's path, not their place in the list
    try h.click("Refresh");
    try h.listDrives(&.{ file_target, sd_card });
    try h.click("Select");
    try testing.expectEqualStrings("/tmp/target.img", h.state().target.?.path);
}
