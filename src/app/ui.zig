//! The OpenEtcher interface: fabrum.app components over a plain model.
//!
//! Nothing here touches the window, the renderer or the disk. The shell in
//! `main.zig` provides `model.Services` and `model.Icons` to the runtime as
//! root values; the tests below provide fakes and drive the interface with
//! `app.testing.Harness`, clicking as a user would.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;

pub const model = @import("ui/model.zig");
pub const theme = @import("ui/theme.zig");
pub const format = @import("ui/format.zig");
pub const App = @import("ui/App.zig");
pub const DriveSelector = @import("ui/DriveSelector.zig");
pub const steps = @import("ui/steps.zig");

test {
    _ = format;
    _ = model;
}

const testing = std.testing;
const Harness = app.testing.Harness(.{}, App);

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
    /// This fake as the services provided to the interface.
    interface: model.Services = undefined,

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

    /// A harness over `App` with this fake and `fake_icons` provided. The
    /// fake must outlive it. Start it with `frame`.
    fn harness(self: *FakeServices) !Harness {
        self.interface = self.services();
        return .init(.{}, .{ .viewport = .init(800, 480), .provide = &.{ .of(&self.interface), .of(&fake_icons) } });
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

/// Chooses an image in the file picker and has it load as `size` bytes.
fn chooseImage(h: *Harness, fake: *FakeServices, path: []const u8, size: u64) !void {
    try h.click("Flash from file");
    try h.post(fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, path)));
    const id = fake.loads.getLast().id;
    try h.post(fake.loaded.?.loaded, model.ImageLoad{ .id = id, .result = .{ .ready = .{ .size = size, .file_size = size, .layout = "mbr" } } });
}

/// Answers the latest drive listing with copies of `drives`.
fn answerDrives(h: *Harness, fake: *FakeServices, drives: []const model.Drive) !void {
    const items = try testing.allocator.alloc(model.Drive, drives.len);
    for (drives, items) |drive, *item| item.* = try drive.clone(testing.allocator);
    try h.post(fake.listed.?, model.DriveListing{ .listed = .{ .items = items } });
}

const sd_card: model.Drive = .{ .path = "/dev/disk4", .name = "SD Card Reader", .location = "/dev/disk4", .size = 31_914_983_424, .system = false, .removable = true };
const internal: model.Drive = .{ .path = "/dev/disk0", .name = "APPLE SSD", .location = "/dev/disk0", .size = 500_000_000_000, .system = true, .removable = false };
const tiny: model.Drive = .{ .path = "/dev/disk5", .name = "Tiny Stick", .location = "/dev/disk5", .size = 1_000_000, .system = false, .removable = true };
const file_target: model.Drive = .{ .path = "/tmp/target.img", .name = "target.img", .location = "/tmp/target.img", .size = 64 << 20, .system = false, .removable = false, .file = true };

test "choosing an image loads it and enables the target step" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try h.expectText("Flash from file");
    try h.expectText("Select target");
    // nothing to write yet: the target and flash buttons are disabled
    try h.click("Select target");
    try testing.expectEqual(0, fake.lists);

    try h.click("Flash from file");
    try h.post(fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/raspios.img.xz")));
    try testing.expectEqual(1, fake.loads.items.len);
    try testing.expectEqualStrings("/images/raspios.img.xz", fake.loads.items[0].path);
    try h.expectText("raspios.img.xz");
    try h.expectText("Reading image\u{2026}");
    try h.post(fake.loaded.?.progress, model.ImageProgress{ .id = fake.loads.items[0].id, .loading = .{ .decoded = 125, .total = 500 } });
    try h.expectText("Decompressing\u{2026} 25%");

    try h.post(fake.loaded.?.loaded, model.ImageLoad{ .id = fake.loads.items[0].id, .result = .{ .ready = .{
        .size = 2_700_000_000,
        .file_size = 500_000_000,
        .compression = "xz",
        .layout = "mbr",
    } } });
    try h.expectText("2.70 GB \u{00b7} xz");

    try h.click("Select target");
    try testing.expectEqual(1, fake.lists);
    try h.expectText("Looking for drives\u{2026}");
}

test "canceling the file picker or a stale load changes nothing" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try h.click("Flash from file");
    try h.post(fake.picked.?, @as(?[]u8, null));
    try testing.expectEqual(null, h.state().image);

    try h.click("Flash from file");
    try h.post(fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/first.img")));
    try h.click("Remove");
    try testing.expectEqual(1, fake.unloads);
    try h.click("Flash from file");
    try h.post(fake.picked.?, @as(?[]u8, try testing.allocator.dupe(u8, "/images/second.iso")));
    // the first image's result arrives after the second was chosen
    try h.post(fake.loaded.?.loaded, model.ImageLoad{ .id = fake.loads.items[0].id, .result = .{ .failed = error.InvalidImage } });
    try testing.expect(h.state().image.?.status == .loading);
    try h.expectText("second.iso");

    try h.post(fake.loaded.?.loaded, model.ImageLoad{ .id = fake.loads.items[1].id, .result = .{ .failed = error.InvalidImage } });
    try h.expectText(model.describeError(error.InvalidImage));

    try h.click("Remove");
    try testing.expectEqual(null, h.state().image);
    try testing.expectEqual(2, fake.unloads);
    try h.expectText("Flash from file");
}

test "the drive selector hides system drives and refuses ones too small" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 2_000_000_000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{ internal, sd_card, tiny });

    try h.expectText("SD Card Reader");
    try h.expectNoText("APPLE SSD");
    try h.expectText("TOO SMALL");

    // too small to pick, so Select stays disabled
    try h.click("Tiny Stick");
    try h.click("Select");
    try testing.expectEqual(null, h.state().target);
    try testing.expectEqual(App.State.Dialog.drives, h.state().dialog);

    try h.click("Show 1 hidden");
    try h.expectText("APPLE SSD");
    try h.expectText("SYSTEM DRIVE");
    try h.click("Hide 1 system drive");
    try h.expectNoText("APPLE SSD");

    try h.click("SD Card Reader");
    try h.click("Select");
    try testing.expectEqual(App.State.Dialog.none, h.state().dialog);
    try testing.expectEqualStrings("/dev/disk4", h.state().target.?.path);
    try h.expectText("31.9 GB");
    try h.expectText("Change");

    // reopening starts from the current target, and Cancel keeps it
    try h.click("Change");
    try testing.expectEqual(2, fake.lists);
    try answerDrives(&h, &fake, &.{sd_card});
    try h.click("Cancel");
    try testing.expectEqualStrings("/dev/disk4", h.state().target.?.path);
}

test "flashing a drive asks first, reports progress and finishes" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 2_000_000_000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{sd_card});
    try h.click("SD Card Reader");
    try h.click("Select");

    try h.click("Flash!");
    try h.expectText("Erase SD Card Reader?");
    try testing.expectEqual(null, fake.flash);
    try h.click("Cancel");
    try testing.expectEqual(null, fake.flash);

    try h.click("Flash!");
    try h.click("Yes, flash it");
    try testing.expectEqualStrings("/dev/disk4", fake.flash_target.?);
    try h.expectText("Starting\u{2026}");
    // nothing can change while flashing
    try h.expectNoText("Remove");
    try h.expectNoText("Change");

    const ms = std.time.ns_per_ms;
    const handlers = fake.flash.?;
    try h.post(handlers.progress, model.FlashProgress{ .phase = .flashing, .completed = 0, .total = 2_000_000_000, .at_ns = 1000 * ms });
    try h.post(handlers.progress, model.FlashProgress{ .phase = .flashing, .completed = 500_000_000, .total = 2_000_000_000, .at_ns = 2000 * ms });
    try h.expectText("Flashing\u{2026} 25%");
    try h.expectText("500 MB/s \u{00b7} ETA 3s");

    try h.post(handlers.progress, model.FlashProgress{ .phase = .verifying, .completed = 1_000_000_000, .total = 2_000_000_000, .at_ns = 6000 * ms });
    try h.expectText("Validating\u{2026} 50%");

    try h.post(handlers.done, model.FlashOutcome{ .done = .{ .image_size = 2_000_000_000, .bytes_written = 2_000_000_000, .elapsed_ns = 8000 * ms } });
    try h.expectText("Flash Complete!");
    try h.expectText("os.img was written to SD Card Reader and validated.");
    try h.expectText("Wrote 2.00 GB in 8s \u{00b7} 250 MB/s");

    try h.click("Flash another");
    try testing.expectEqual(null, h.state().target);
    try testing.expect(h.state().image != null);
    try h.expectText("Select target");
}

test "system drives get a stronger warning, file targets none" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 1000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{ internal, file_target });
    try h.click("Show 1 hidden");
    try h.click("APPLE SSD");
    try h.click("Select");
    try h.expectText("System drive");
    try h.click("Flash!");
    try h.expectText("This is a system drive. Writing to it can leave this Mac unable to start.");
    try h.click("Cancel");

    try h.click("Change");
    try answerDrives(&h, &fake, &.{ internal, file_target });
    try h.click("target.img");
    try h.click("Select");
    try h.click("Flash!");
    // straight to work
    try testing.expectEqualStrings("/tmp/target.img", fake.flash_target.?);
}

test "canceling a flash asks the services once and shows how it ended" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 1000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{file_target});
    try h.click("target.img");
    try h.click("Select");
    try h.click("Flash!");

    try h.click("Cancel");
    try testing.expectEqual(1, fake.cancels);
    try h.expectText("Canceling\u{2026}");
    try h.post(fake.flash.?.done, @as(model.FlashOutcome, .canceled));
    try h.expectText("Flash Canceled");

    try h.click("Flash another");
    try h.click("Select target");
    try h.post(fake.listed.?, model.DriveListing{ .failed = error.DiskListFailed });
    try h.expectText("Listing drives failed.");
}

test "a failed flash shows why" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 1000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{sd_card});
    try h.click("SD Card Reader");
    try h.click("Select");
    try h.click("Flash!");
    try h.click("Yes, flash it");
    try h.post(fake.flash.?.done, model.FlashOutcome{ .failed = error.AccessDenied });
    try h.expectText("Flash Failed");
    try h.expectText(model.describeError(error.AccessDenied));
}

test "a relisting that reorders the drives keeps the picked one" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    try chooseImage(&h, &fake, "/images/os.img", 1000);
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{ sd_card, file_target });
    try h.click("target.img");

    // rows follow their drive's path, not their place in the list
    try h.click("Refresh");
    try answerDrives(&h, &fake, &.{ file_target, sd_card });
    try h.click("Select");
    try testing.expectEqualStrings("/tmp/target.img", h.state().target.?.path);
}

test "long names are cut to fit, and keep both ends" {
    var fake: FakeServices = .{};
    defer fake.deinit();
    var h = try fake.harness();
    defer h.deinit();
    try h.frame();

    const long_name = "raspios-bookworm-arm64-lite-2024-11-19-with-desktop-and-recommended-software.img.xz";
    try chooseImage(&h, &fake, "/images/" ++ long_name, 2_000_000_000);
    const name = h.findText(long_name).?;
    try testing.expect(name.bbox.w <= steps.width);

    const drive: model.Drive = .{
        .path = "/dev/disk6",
        .name = "Generic Multi-Card Reader With An Unreasonably Long Product Name",
        .location = "/dev/disk6, /Volumes/A Volume With A Long Name, /Volumes/Another",
        .size = 64_000_000_000,
        .system = false,
        .removable = true,
    };
    try h.click("Select target");
    try answerDrives(&h, &fake, &.{drive});
    // the row's name gives way to the size and location columns
    const row_name = h.findText(drive.name).?;
    const location = h.findText(drive.location).?;
    try testing.expect(row_name.bbox.x + row_name.bbox.w <= location.bbox.x);
    try testing.expect(location.bbox.w <= 170);

    try h.click(drive.name);
    try h.click("Select");
    try h.click("Flash!");
    const title = h.findText("Erase " ++ drive.name ++ "?").?;
    // within the dialog's card, less its padding
    try testing.expect(title.bbox.w <= 440 - 2 * 26);
    var lines = Harness.Text.asTextContent(title.data.content).?.lines(title.bbox.w);
    const shown = (try lines.next()).?;
    try testing.expect(std.mem.startsWith(u8, shown, "Erase "));
    try testing.expect(std.mem.endsWith(u8, shown, "?"));
    try testing.expect(std.mem.indexOf(u8, shown, layout.text.ellipsis) != null);
}
