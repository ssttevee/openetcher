//! OpenEtcher's macOS GUI: the interface in `ui.zig`, run by fabrum.app on
//! its AppKit platform. The window, the image chooser (`NSOpenPanel`), the
//! question before quitting mid-flash (`NSAlert`) and the Quartz canvas the
//! interface is drawn on are the platform's; the interface keeps Etcher's
//! own look, drawn.
//!
//! Debug builds read three environment variables for development and tests:
//!
//! - `OPENETCHER_GUI_FILE_TARGETS`: colon-separated regular files offered as
//!   targets next to the real drives. Setting it also refuses to write to
//!   anything but these files, so a test can never write a disk.
//! - `OPENETCHER_GUI_SCRIPT`: steps to run once the window is up, separated
//!   by `;`: `image=<path>` presses "Flash from file" and answers the file
//!   chooser with the path, `click=<label>` and `hover=<label>` move the
//!   pointer to the text `label` (clicking it), `nsclick=<label>` clicks it
//!   with AppKit events sent through the window, `answer=<index>` answers
//!   the dialog being shown, `close` presses the window's close button,
//!   `wait=<ms>` pauses, `snapshot=<path>` saves the window's content as a
//!   PNG (`snapshot2x=` at two pixels per point, whatever the screen's
//!   scale), and `quit` quits as the menu item would.
//! - `OPENETCHER_GUI_LAYOUT_FILE`: ten times a second, the viewport size and
//!   the bounds of every text, in points from the top left of the window's
//!   content, are written to this file, so tests driving the window with
//!   real input can find what to click.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const appkit = app.platform.appkit;
const automation = appkit.automation;

const ui = @import("ui.zig");
const Services = @import("services.zig");
const Icons = @import("icons.zig");

pub const Gui = appkit.App(ui.App);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const file_targets: []const []const u8 = if (builtin.mode == .debug) targets: {
        const value = env.get("OPENETCHER_GUI_FILE_TARGETS") orelse break :targets &.{};
        var paths: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, value, ':');
        while (it.next()) |path| try paths.append(init.arena.allocator(), path);
        break :targets paths.items;
    } else &.{};

    // everything lives as long as the process, since `run` never returns
    const gui = try gpa.create(Gui);
    const services = try gpa.create(Services);
    const icons = try gpa.create(Icons);
    icons.* = try .init(gpa);
    const provided = try gpa.create(struct { services: ui.model.Services, icons: ui.model.Icons });

    try gui.init(gpa, io, .{}, .{
        .title = "OpenEtcher",
        .width = 800,
        .height = 480,
        .min_width = 720,
        .min_height = 440,
    }, .{
        // filled in below, before the first frame
        .provide = &.{ .of(&provided.services), .of(&provided.icons), .of(&services.work) },
        .on_terminate = .{ .ctx = services, .call = shutdown },
    });
    services.* = .{
        .gpa = gpa,
        .io = io,
        .poster = gui.runtime.poster(),
        .options = .{
            .spool_dir = spoolDir(env),
            .file_targets = file_targets,
            .file_targets_only = file_targets.len > 0,
        },
    };
    try services.start();
    provided.services = services.interface();
    provided.icons = icons.interface();

    if (builtin.mode == .debug) {
        if (env.get("OPENETCHER_GUI_SCRIPT")) |steps| {
            const script = try gpa.create(Script);
            script.* = .{ .gui = gui, .io = io, .steps = std.mem.tokenizeScalar(u8, steps, ';') };
            const group = try gpa.create(Io.Group);
            group.* = .init;
            try group.concurrent(io, Script.run, .{script});
        }
        if (env.get("OPENETCHER_GUI_LAYOUT_FILE")) |path| {
            const writer = try gpa.create(LayoutFile);
            writer.* = .{ .gui = gui, .io = io, .gpa = gpa, .path = path };
            const group = try gpa.create(Io.Group);
            group.* = .init;
            try group.concurrent(io, LayoutFile.run, .{writer});
        }
    }

    gui.run();
}

/// Stops the services before the process exits: a flash is cancelled and
/// waited for, so its target is left synced.
fn shutdown(ctx: ?*anyopaque) void {
    const services: *Services = @ptrCast(@alignCast(ctx.?));
    services.shutdown();
}

/// Where compressed images are decoded, from the usual temporary-directory
/// variables.
fn spoolDir(env: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |name| {
        if (env.get(name)) |value| if (value.len != 0) return value;
    }
    return null;
}

/// Writes the viewport size and the bounds of every text in `context`, one
/// tab-separated line each, in points from the top left of the viewport:
/// `viewport <width> <height>`, then `text <x> <y> <width> <height> <text>`.
fn writeLayout(comptime Text: type, writer: *Io.Writer, context: *const fabrum.layout.Context, viewport: fabrum.Vec2) Io.Writer.Error!void {
    try writer.print("viewport\t{d}\t{d}\n", .{ viewport.x, viewport.y });
    var texts: app.testing.TextIterator(Text) = .init(context);
    while (texts.next()) |found| {
        const box = found.unit.bbox;
        try writer.print("text\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t", .{ box.x, box.y, box.w, box.h });
        for (found.content.text) |byte| try writer.writeByte(if (byte == '\n' or byte == '\t') ' ' else byte);
        try writer.writeByte('\n');
    }
}

test writeLayout {
    const TestRuntime = app.Runtime(.{});
    const Label = struct {
        pub const Props = struct {};
        pub fn view(scope: *app.Ui, _: Props) !void {
            try scope.open(null, .{ .layout = .{ .padding = .init(10, 0, 20, 0) } });
            defer scope.close();
            try scope.text("Flash!\tnow", .{ .font_size = 10, .line_height = 1 });
        }
    };

    var runtime: TestRuntime = try .init(std.testing.allocator, .{ .io = std.testing.io });
    defer runtime.deinit();
    _ = try runtime.frame(Label, .{}, .init(800, 480), .zero);

    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeLayout(TestRuntime.Text, &writer, runtime.context(), .init(800, 480));
    try std.testing.expectEqualStrings("viewport\t800\t480\ntext\t10.0\t20.0\t58.0\t10.0\tFlash! now\n", writer.buffered());
}

/// Replaces the file at `path` with the layout of the last frame, ten times
/// a second (`OPENETCHER_GUI_LAYOUT_FILE`). The file is replaced whole, so
/// readers never see half of it.
const LayoutFile = struct {
    gui: *Gui,
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,

    fn run(self: *LayoutFile) Io.Cancelable!void {
        while (true) {
            try self.io.sleep(.fromMilliseconds(100), .awake);
            automation.runOnMain(onMain, self);
        }
    }

    fn onMain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *LayoutFile = @ptrCast(@alignCast(ctx.?));
        self.write() catch |err| std.log.err("writing the layout file failed: {t}", .{err});
    }

    fn write(self: *LayoutFile) !void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try writeLayout(Gui.Runtime.Text, &out.writer, self.gui.runtime.context(), self.gui.viewport);

        var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp", .{self.path});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = temp, .data = out.written() });
        try cwd.rename(temp, cwd, self.path, self.io);
    }
};

/// Drives the interface from `OPENETCHER_GUI_SCRIPT` in debug builds, in
/// process: pointer events fed to the runtime, and fabrum's AppKit
/// automation for the chooser, dialogs and snapshots. Nothing reaches the
/// system's event stream and the real pointer never moves.
const Script = struct {
    gui: *Gui,
    io: Io,
    steps: std.mem.TokenIterator(u8, .scalar),
    /// The step handed to the main thread, and a signal that it ran.
    step: []const u8 = "",
    done: Io.Event = .unset,
    /// The path an `image=` step answers the chooser with, once it is up.
    image: [std.fs.max_path_bytes:0]u8 = undefined,

    fn run(self: *Script) Io.Cancelable!void {
        // let the window come up
        try self.io.sleep(.fromMilliseconds(800), .awake);
        while (self.steps.next()) |step| {
            if (std.mem.startsWith(u8, step, "wait=")) {
                const ms = std.fmt.parseInt(u32, step["wait=".len..], 10) catch 0;
                try self.io.sleep(.fromMilliseconds(ms), .awake);
                continue;
            }
            self.step = step;
            self.done.reset();
            automation.runOnMain(onMain, self);
            try self.done.wait(self.io);
            // give the frame it caused time to draw
            try self.io.sleep(.fromMilliseconds(150), .awake);
        }
    }

    fn onMain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        defer self.done.set(self.io);
        self.perform(self.step) catch |err| std.log.err("script step \"{s}\" failed: {t}", .{ self.step, err });
    }

    fn perform(self: *Script, step: []const u8) !void {
        if (std.mem.startsWith(u8, step, "image=")) {
            // the chooser opens as a sheet after the click's frame, so it
            // is answered from the next turn of the main queue
            _ = try std.fmt.bufPrintSentinel(&self.image, "{s}", .{step["image=".len..]}, 0);
            try self.click("Flash from file", true);
            return automation.runOnMain(answerChooser, self);
        }
        if (std.mem.startsWith(u8, step, "click=")) return self.click(step["click=".len..], true);
        if (std.mem.startsWith(u8, step, "hover=")) return self.click(step["hover=".len..], false);
        if (std.mem.startsWith(u8, step, "nsclick=")) {
            const point = app.testing.center(try self.findText(step["nsclick=".len..]));
            return automation.windowClick(point.x, point.y);
        }
        if (std.mem.startsWith(u8, step, "answer=")) return automation.answerAlert(try std.fmt.parseInt(usize, step["answer=".len..], 10));
        if (std.mem.eql(u8, step, "close")) return automation.runOnMain(closeLater, null);
        if (std.mem.startsWith(u8, step, "snapshot=")) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            return automation.snapshot(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{step["snapshot=".len..]}, 0), null);
        }
        if (std.mem.startsWith(u8, step, "snapshot2x=")) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            return automation.snapshot(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{step["snapshot2x=".len..]}, 0), 2);
        }
        // quitting may show an alert, whose modal loop must not hold up the script
        if (std.mem.eql(u8, step, "quit")) return automation.runOnMain(quitLater, null);
        return error.UnknownStep;
    }

    fn answerChooser(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        automation.answerFileChooser(std.mem.span(@as([*:0]const u8, &self.image))) catch |err| std.log.err("answering the file chooser failed: {t}", .{err});
    }

    fn quitLater(_: ?*anyopaque) callconv(.c) void {
        automation.quit();
    }

    fn closeLater(_: ?*anyopaque) callconv(.c) void {
        automation.close();
    }

    fn click(self: *Script, label: []const u8, press: bool) !void {
        const point = app.testing.center(try self.findText(label));
        Gui.mouse(self.gui, point.x, point.y, 0, 0, 0);
        if (press) {
            Gui.mouse(self.gui, point.x, point.y, 1, 0, 0);
            Gui.mouse(self.gui, point.x, point.y, 0, 0, 0);
        }
    }

    /// The text `label` in the last frame, as the tests find it.
    fn findText(self: *Script, label: []const u8) error{NoSuchText}!*const fabrum.layout.Unit {
        return app.testing.findText(Gui.Runtime.Text, self.gui.runtime.context(), label) orelse error.NoSuchText;
    }
};

test {
    _ = ui;
    _ = Services;
    _ = Icons;
}
