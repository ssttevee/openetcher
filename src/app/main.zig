//! OpenEtcher's macOS GUI: the interface in `ui.zig`, run by fabrum.app in
//! the AppKit shell and drawn with the Quartz renderer.
//!
//! Debug builds read two environment variables for development and tests:
//!
//! - `OPENETCHER_GUI_FILE_TARGETS`: colon-separated regular files offered as
//!   targets next to the real drives. Setting it also refuses to write to
//!   anything but these files, so a test can never write a disk.
//! - `OPENETCHER_GUI_SCRIPT`: steps to run once the window is up, separated
//!   by `;`: `image=<path>` chooses an image as the file picker would,
//!   `click=<label>` and `hover=<label>` move the pointer to the text
//!   `label` (clicking it), `nsclick=<label>` clicks it with AppKit events
//!   sent through the window, `wait=<ms>` pauses, `snapshot=<path>` saves the
//!   window's content as a PNG (`snapshot2x=` at two pixels per point,
//!   whatever the screen's scale), and `quit` quits as the menu item would.
//! - `OPENETCHER_GUI_LAYOUT_FILE`: after every frame, the viewport size and
//!   the bounds of every text, in points from the top left of the window's
//!   content, are written to this file, so tests driving the window with
//!   real input can find what to click.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const Quartz = @import("fabrum-renderer-quartz");

const ui = @import("ui.zig");
const Services = @import("services.zig");
const Icons = @import("icons.zig");
const shell = @import("platform/macos/shell.zig");

const Runtime = app.Runtime(.{ .Text = Quartz.content.Text });

const Gui = struct {
    gpa: std.mem.Allocator,
    io: Io,
    runtime: Runtime,
    renderer: Quartz,
    icons: Icons,
    services: Services,
    /// Provided to the interface as root values.
    services_interface: ui.model.Services,
    icons_interface: ui.model.Icons,
    /// Set by a script's `image=` step: the next pick answers with it.
    scripted_pick: ?[]const u8 = null,
    /// From `OPENETCHER_GUI_LAYOUT_FILE`, in debug builds.
    layout_file: ?[]const u8 = null,

    fn draw(ctx: *anyopaque, cg: *shell.CGContext, width: f64, height: f64) callconv(.c) void {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        var commands = self.runtime.frame(ui.App, .{}, .init(@floatCast(width), @floatCast(height))) catch |err| {
            std.log.err("frame failed: {t}", .{err});
            return;
        };
        const quartz_cg: *Quartz.CGContext = @ptrCast(cg);
        quartz_cg.flipCanvas(height);
        self.renderer.render(&commands, quartz_cg) catch |err| std.log.err("render failed: {t}", .{err});
        if (self.layout_file) |path| {
            self.saveLayout(path, .init(@floatCast(width), @floatCast(height))) catch |err| std.log.err("saving the layout failed: {t}", .{err});
        }
        self.afterInput();
    }

    /// Replaces the file at `path` with the layout of the last frame.
    fn saveLayout(self: *Gui, path: []const u8, viewport: fabrum.Vec2) !void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try writeLayout(Quartz.content.Text, &out.writer, self.runtime.context(), viewport);

        // readers never see a half-written file
        var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp", .{path});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = temp, .data = out.written() });
        try cwd.rename(temp, cwd, path, self.io);
    }

    fn mouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        var pressed: app.MouseEvent.Buttons = .empty;
        if (buttons & 1 != 0) pressed.set(app.MouseEvent.primary);
        self.runtime.mouse(.{
            .position = .init(@floatCast(x), @floatCast(y)),
            .pressed = pressed,
            .scroll_delta = .init(@floatCast(scroll_x), @floatCast(scroll_y)),
        }) catch |err| std.log.err("input failed: {t}", .{err});
        self.afterInput();
    }

    fn afterInput(self: *Gui) void {
        shell.setCursor(self.runtime.cursor());
        if (self.runtime.needsFrame()) shell.requestRedraw();
    }

    fn busy(ctx: *anyopaque) callconv(.c) ?[*:0]const u8 {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        if (!self.services.flashing()) return null;
        return "Quitting stops the flash and leaves the target partly written.";
    }

    fn willTerminate(ctx: *anyopaque) callconv(.c) void {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        self.services.shutdown();
    }

    fn choose(ctx: ?*anyopaque, extensions: []const [*:0]const u8, services: *Services) void {
        const self: *Gui = @ptrCast(@alignCast(ctx.?));
        if (self.scripted_pick) |path| {
            self.scripted_pick = null;
            return services.picked(path);
        }
        shell.chooseFile("Choose an image to flash", extensions, chosen, services);
    }

    fn chosen(ctx: ?*anyopaque, path: ?[*]const u8, len: usize) callconv(.c) void {
        const services: *Services = @ptrCast(@alignCast(ctx.?));
        services.picked(if (path) |p| p[0..len] else null);
    }
};

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

    var gui: Gui = .{
        .layout_file = if (builtin.mode == .debug) env.get("OPENETCHER_GUI_LAYOUT_FILE") else null,
        .gpa = gpa,
        .io = io,
        .runtime = undefined,
        .renderer = try .init(gpa),
        .icons = try .init(gpa),
        .services = undefined,
        .services_interface = undefined,
        .icons_interface = undefined,
    };
    gui.runtime = try .init(gpa, .{
        .io = io,
        .text_context = gui.renderer.text_context,
        .platform = shell.platform,
        // filled in below, before the first frame
        .provide = &.{ .of(&gui.services_interface), .of(&gui.icons_interface) },
    });
    gui.services = .{
        .gpa = gpa,
        .io = io,
        .poster = gui.runtime.poster(),
        .picker = .{ .ctx = &gui, .choose = Gui.choose },
        .options = .{
            .spool_dir = spoolDir(env),
            .file_targets = file_targets,
            .file_targets_only = file_targets.len > 0,
        },
    };
    try gui.services.start();
    gui.services_interface = gui.services.interface();
    gui.icons_interface = gui.icons.interface();

    var script: Script = .{ .gui = &gui };
    var script_group: Io.Group = .init;
    if (builtin.mode == .debug) {
        if (env.get("OPENETCHER_GUI_SCRIPT")) |steps| {
            script.steps = std.mem.tokenizeScalar(u8, steps, ';');
            try script_group.concurrent(io, Script.run, .{&script});
        }
    }

    shell.run(.{ .title = "OpenEtcher" }, .{
        .ctx = &gui,
        .draw = Gui.draw,
        .mouse = Gui.mouse,
        .busy = Gui.busy,
        .will_terminate = Gui.willTerminate,
    });
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
    _ = try runtime.frame(Label, .{}, .init(800, 480));

    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeLayout(TestRuntime.Text, &writer, runtime.context(), .init(800, 480));
    try std.testing.expectEqualStrings("viewport\t800\t480\ntext\t10.0\t20.0\t58.0\t10.0\tFlash! now\n", writer.buffered());
}

/// Drives the interface from `OPENETCHER_GUI_SCRIPT` in debug builds, with
/// the same pointer events a user's clicks make.
const Script = struct {
    gui: *Gui,
    steps: std.mem.TokenIterator(u8, .scalar) = undefined,
    /// The step handed to the main thread, and a signal that it ran.
    step: []const u8 = "",
    done: Io.Event = .unset,

    fn run(self: *Script) Io.Cancelable!void {
        const io = self.gui.io;
        // let the window come up
        try io.sleep(.fromMilliseconds(800), .awake);
        while (self.steps.next()) |step| {
            if (std.mem.startsWith(u8, step, "wait=")) {
                const ms = std.fmt.parseInt(u32, step["wait=".len..], 10) catch 0;
                try io.sleep(.fromMilliseconds(ms), .awake);
                continue;
            }
            self.step = step;
            self.done.reset();
            shell.runOnMain(onMain, self);
            try self.done.wait(io);
            // give the frame it caused time to draw
            try io.sleep(.fromMilliseconds(150), .awake);
        }
    }

    fn onMain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        defer self.done.set(self.gui.io);
        self.perform(self.step) catch |err| std.log.err("script step \"{s}\" failed: {t}", .{ self.step, err });
    }

    fn perform(self: *Script, step: []const u8) !void {
        const gui = self.gui;
        if (std.mem.startsWith(u8, step, "image=")) {
            gui.scripted_pick = step["image=".len..];
            return self.click("Flash from file", true);
        }
        if (std.mem.startsWith(u8, step, "click=")) return self.click(step["click=".len..], true);
        if (std.mem.startsWith(u8, step, "hover=")) return self.click(step["hover=".len..], false);
        if (std.mem.startsWith(u8, step, "nsclick=")) {
            const point = app.testing.center(try findText(gui, step["nsclick=".len..]));
            return shell.synthesizeClick(point.x, point.y);
        }
        if (std.mem.startsWith(u8, step, "snapshot=")) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            return shell.snapshot(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{step["snapshot=".len..]}, 0));
        }
        if (std.mem.startsWith(u8, step, "snapshot2x=")) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            return shell.snapshotScaled(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{step["snapshot2x=".len..]}, 0), 2);
        }
        // quitting may show an alert, whose modal loop must not hold up the script
        if (std.mem.eql(u8, step, "quit")) return shell.runOnMain(quitLater, null);
        return error.UnknownStep;
    }

    fn quitLater(_: ?*anyopaque) callconv(.c) void {
        shell.quit();
    }

    fn click(self: *Script, label: []const u8, press: bool) !void {
        const gui = self.gui;
        const point = app.testing.center(try findText(gui, label));
        Gui.mouse(gui, point.x, point.y, 0, 0, 0);
        if (press) {
            Gui.mouse(gui, point.x, point.y, 1, 0, 0);
            Gui.mouse(gui, point.x, point.y, 0, 0, 0);
        }
    }

    /// The text `label` in the last frame, as the tests find it.
    fn findText(gui: *Gui, label: []const u8) error{NoSuchText}!*const fabrum.layout.Unit {
        return app.testing.findText(Runtime.Text, gui.runtime.context(), label) orelse error.NoSuchText;
    }
};

test {
    _ = ui;
    _ = Services;
    _ = Icons;
}
