//! The macOS shell around a fabrum app: an AppKit window that draws through
//! a `Host` and feeds it the mouse, a file picker and the cursor.
//!
//! This knows nothing about OpenEtcher; it only depends on `fabrum.app`, so
//! that it can become a fabrum platform package.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

/// A Core Graphics context, as the Quartz renderer takes it.
pub const CGContext = opaque {};

pub const Options = struct {
    title: [:0]const u8,
    width: f64 = 800,
    height: f64 = 480,
    min_width: f64 = 720,
    min_height: f64 = 440,
};

/// What the shell calls back into. Every call is on the main thread.
pub const Host = extern struct {
    ctx: *anyopaque,
    /// Draws a frame of `width` by `height` points into `cg`, whose origin
    /// is the bottom left.
    draw: *const fn (ctx: *anyopaque, cg: *CGContext, width: f64, height: f64) callconv(.c) void,
    /// The pointer, from the top left of the window's content in points.
    /// Bit 0 of `buttons` is the primary button.
    mouse: *const fn (ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void,
    /// Why quitting now needs confirmation, or null.
    busy: *const fn (ctx: *anyopaque) callconv(.c) ?[*:0]const u8,
    /// Called once before the process exits.
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
};

const COptions = extern struct {
    title: [*:0]const u8,
    width: f64,
    height: f64,
    min_width: f64,
    min_height: f64,
};

extern fn fabrum_shell_run(options: COptions, host: Host) callconv(.c) noreturn;
extern fn fabrum_shell_request_frame() callconv(.c) void;
extern fn fabrum_shell_set_cursor(cursor: c_int) callconv(.c) void;
extern fn fabrum_shell_quit() callconv(.c) void;
extern fn fabrum_shell_snapshot_scaled(path: [*:0]const u8, scale: f64) callconv(.c) bool;
extern fn fabrum_shell_synthesize_click(x: f64, y: f64) callconv(.c) void;
extern fn fabrum_shell_snapshot(path: [*:0]const u8) callconv(.c) bool;
extern fn fabrum_shell_run_on_main(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_shell_choose_file(
    message: [*:0]const u8,
    extensions: [*]const [*:0]const u8,
    extension_count: usize,
    done: *const fn (ctx: ?*anyopaque, path: ?[*]const u8, len: usize) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) void;

/// Opens the window and runs the app until it quits.
pub fn run(options: Options, host: Host) noreturn {
    fabrum_shell_run(.{
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .min_width = options.min_width,
        .min_height = options.min_height,
    }, host);
}

/// The `fabrum.app.Platform` of this shell: frames are requested by marking
/// the view as needing display on the main thread.
pub const platform: app.Platform = .{ .ptr = undefined, .vtable = &.{ .requestFrame = requestFrame } };

fn requestFrame(_: *anyopaque) void {
    fabrum_shell_request_frame();
}

/// Asks for a frame from any thread.
pub fn requestRedraw() void {
    fabrum_shell_request_frame();
}

pub fn setCursor(cursor: app.Cursor) void {
    fabrum_shell_set_cursor(switch (cursor) {
        .default => 0,
        .pointer => 1,
    });
}

/// Called on the main thread with the chosen path, or null if the user
/// canceled. The path is only valid during the call.
pub const FileCallback = *const fn (ctx: ?*anyopaque, path: ?[*]const u8, len: usize) callconv(.c) void;

/// Shows a file picker over the window, after the current event is
/// handled, limited to files with one of `extensions`.
pub fn chooseFile(message: [:0]const u8, extensions: []const [*:0]const u8, done: FileCallback, ctx: ?*anyopaque) void {
    fabrum_shell_choose_file(message, extensions.ptr, extensions.len, done, ctx);
}

/// Runs `callback(ctx)` on the main thread after the current event, from
/// any thread.
pub fn runOnMain(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    fabrum_shell_run_on_main(callback, ctx);
}

/// Draws the window's content and saves it as a PNG at `path`, at the
/// screen's scale. Main thread only.
pub fn snapshot(path: [:0]const u8) error{SnapshotFailed}!void {
    if (!fabrum_shell_snapshot(path)) return error.SnapshotFailed;
}

/// Quits as the Quit menu item does, asking first if the host is busy.
/// Main thread only.
pub fn quit() void {
    fabrum_shell_quit();
}

/// Clicks at `x`, `y` (points from the top left of the content) by sending
/// AppKit mouse events through the window, as a user's click would arrive.
/// For tests. Main thread only.
pub fn synthesizeClick(x: f64, y: f64) void {
    fabrum_shell_synthesize_click(x, y);
}

/// Like `snapshot`, at `scale` pixels per point whatever the screen's
/// scale. Main thread only.
pub fn snapshotScaled(path: [:0]const u8, scale: f64) error{SnapshotFailed}!void {
    if (!fabrum_shell_snapshot_scaled(path, scale)) return error.SnapshotFailed;
}
