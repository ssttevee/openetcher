//! The root component: the shared model of the image, the target and the
//! flash, and the screen built from it.
//!
//! The steps and dialogs are child components whose buttons fire the app's
//! messages. Work that takes time or touches the system goes through the
//! runtime tasks or the flash `model.Services`, whose answers come back as
//! messages. The image is chosen with the platform's own file chooser
//! (`Update.openFile`), and while a flash runs, closing the window or
//! quitting is held for the platform's own question (`ui.guardClose`,
//! `Update.confirm`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;

const model = @import("model.zig");
pub const tasks = @import("../tasks.zig");
const theme = @import("theme.zig");
const steps = @import("steps.zig");
const DriveSelector = @import("DriveSelector.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const Finish = @import("Finish.zig");

const App = @This();

pub const State = struct {
    image: ?model.Image = null,
    /// The id the next chosen image gets.
    next_image_id: u32 = 1,
    target: ?model.Drive = null,
    /// The latest drive listing, for the selector.
    drives: Drives = .idle,
    dialog: Dialog = .none,
    drive_refresh: u32 = 0,
    flash: Flash = .idle,

    pub const Drives = union(enum) {
        idle,
        loading,
        listed: model.DriveList,
        failed: anyerror,
    };

    pub const Dialog = enum { none, drives, confirm };

    pub const Flash = union(enum) {
        idle,
        running: model.Running,
        finished: model.FlashOutcome,
    };

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.image) |image| image.deinit(gpa);
        if (self.target) |target| target.deinit(gpa);
        self.setDrives(gpa, .idle);
        self.* = undefined;
    }

    fn setDrives(self: *State, gpa: Allocator, drives: Drives) void {
        switch (self.drives) {
            .listed => |list| list.deinit(gpa),
            else => {},
        }
        self.drives = drives;
    }

    fn setTarget(self: *State, gpa: Allocator, target: ?model.Drive) void {
        if (self.target) |old| old.deinit(gpa);
        self.target = target;
    }

    pub fn flashing(self: *const State) bool {
        return self.flash == .running;
    }

    /// Whether everything is chosen, and the image fits the target.
    pub fn ready(self: *const State) bool {
        const image = self.image orelse return false;
        const target = self.target orelse return false;
        const size = image.size() orelse return false;
        return self.flash == .idle and target.size >= size;
    }
};

pub const Msg = union(enum) {
    pick_image,
    /// The chooser's answer: a path the message borrows, or null if the
    /// user cancelled.
    image_picked: ?[]const u8,
    image_progress: model.ImageProgress,
    image_loaded: model.ImageLoad,
    remove_image,
    image_unloaded,

    open_drives,
    refresh_drives,
    /// Owned by the message.
    drives_listed: model.DriveListing,
    close_drives,
    /// An index into the listed drives.
    select_drive: usize,

    request_flash,
    confirm_flash,
    cancel_confirm,
    flash_progress: model.FlashProgress,
    flash_done: model.FlashOutcome,
    cancel_flash,
    flash_another,
    /// The window's close button or quitting, while a flash runs.
    close_requested: app.platform.CloseReason,
    /// The answer: 0 keeps flashing, 1 quits.
    quit_answered: ?usize,

    pub fn deinit(self: *Msg, gpa: Allocator) void {
        switch (self.*) {
            .drives_listed => |listing| listing.deinit(gpa),
            else => {},
        }
    }
};

pub const Props = struct {};

pub fn update(state: *State, msg: Msg, ctx: *app.Update(App)) !void {
    const gpa = ctx.gpa;
    const services = ctx.use(model.Services);
    switch (msg) {
        .pick_image => if (!state.flashing()) try ctx.openFile(.{ .message = "Choose an image to flash", .extensions = model.image_extensions }, ctx.handler(.image_picked)),
        .image_picked => |picked| {
            const borrowed = picked orelse return;
            if (state.flashing()) return;
            const path = try gpa.dupe(u8, borrowed);
            if (state.image) |old| old.deinit(gpa);
            const id = state.next_image_id;
            state.next_image_id +%= 1;
            state.image = .{ .id = id, .path = path };
            try ctx.runKey("image", tasks.loadImage, .{ @constCast(ctx.use(tasks.Work)), id, path, ctx.handler(.image_progress) }, ctx.handler(.image_loaded));
        },
        .image_progress => |progress| {
            const image = if (state.image) |*image| image else return;
            if (image.id != progress.id or image.status != .loading) return;
            image.status = .{ .loading = progress.loading };
        },
        .image_loaded => |load| {
            const image = if (state.image) |*image| image else return;
            // a result for an image that was replaced or removed meanwhile
            if (image.id != load.id) return;
            const status: model.Image.Status = switch (load.result) {
                .ready => |details| .{ .ready = try details.clone(gpa) },
                .failed => |err| .{ .failed = err },
            };
            image.status.deinit(gpa);
            image.status = status;
        },
        .remove_image => {
            if (state.flashing()) return;
            const image = state.image orelse return;
            image.deinit(gpa);
            state.image = null;
            try ctx.runKey("image", tasks.unloadImage, .{@constCast(ctx.use(tasks.Work))}, ctx.handler(.image_unloaded));
        },

        .image_unloaded => {},

        .open_drives => {
            if (state.flashing() or state.image == null) return;
            state.dialog = .drives;
            state.setDrives(gpa, .loading);
            state.drive_refresh +%= 1;
        },
        .refresh_drives => {
            state.setDrives(gpa, .loading);
            state.drive_refresh +%= 1;
        },
        .drives_listed => |listing| state.setDrives(gpa, switch (listing) {
            .listed => |list| .{ .listed = try list.clone(gpa) },
            .failed => |err| .{ .failed = err },
        }),
        .close_drives => state.dialog = .none,
        .select_drive => |index| {
            const list = switch (state.drives) {
                .listed => |list| list,
                else => return,
            };
            if (index >= list.items.len or state.flashing()) return;
            state.setTarget(gpa, try list.items[index].clone(gpa));
            state.dialog = .none;
        },

        .request_flash => {
            if (!state.ready()) return;
            // writing a file destroys nothing the user didn't point at; a drive gets a second look
            if (state.target.?.file) return start(state, ctx);
            state.dialog = .confirm;
        },
        .confirm_flash => {
            state.dialog = .none;
            if (state.ready()) start(state, ctx);
        },
        .cancel_confirm => state.dialog = .none,
        .flash_progress => |sample| switch (state.flash) {
            .running => |*running| running.advance(sample),
            else => {},
        },
        .flash_done => |outcome| {
            if (state.flash != .running) return;
            state.flash = .{ .finished = outcome };
        },
        .cancel_flash => switch (state.flash) {
            .running => |*running| if (!running.canceling) {
                running.canceling = true;
                services.cancelFlash();
            },
            else => {},
        },
        .flash_another => {
            if (state.flash != .finished) return;
            state.flash = .idle;
            state.setTarget(gpa, null);
        },
        .close_requested => try ctx.confirm(.{
            .title = "Quit while flashing?",
            .text = "Quitting stops the flash and leaves the target partly written.",
            .buttons = &.{ "Keep Flashing", "Quit" },
            .kind = .warning,
        }, ctx.handler(.quit_answered)),
        .quit_answered => |button| if (button == 1) try ctx.quit(),
    }
}

fn start(state: *State, ctx: *app.Update(App)) void {
    state.flash = .{ .running = .{} };
    ctx.use(model.Services).startFlash(state.image.?.id, &state.target.?, .{
        .progress = ctx.handler(.flash_progress),
        .done = ctx.handler(.flash_done),
    });
}

pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
    try ui.open(null, .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_alignment = .top_center },
        .background_color = theme.window_background,
    });
    defer ui.close();

    try header(ui);

    const on = ui.messages(App);
    // closing or quitting mid-flash asks first
    if (state.flashing()) ui.guardClose(on.handler(.close_requested));
    switch (state.flash) {
        .finished => |outcome| try ui.one(Finish, .{
            .outcome = outcome,
            .image_name = if (state.image) |image| image.name() else "",
            .drive_name = if (state.target) |target| target.name else "",
            .on_again = on.bind(.flash_another),
        }),
        else => try stepsRow(ui, state),
    }

    switch (state.dialog) {
        .none => {},
        .drives => {
            try ui.task(.{ "drives", state.drive_refresh }, tasks.listDrives, .{ui.use(tasks.Work).options.file_targets}, on.handler(.drives_listed));
            try ui.one(DriveSelector, .{
                .drives = switch (state.drives) {
                    .listed => |list| list.items,
                    else => &.{},
                },
                .loading = state.drives == .loading or state.drives == .idle,
                .failure = switch (state.drives) {
                    .failed => |err| err,
                    else => null,
                },
                .image_size = if (state.image) |image| image.size() else null,
                .current = if (state.target) |target| target.path else null,
                .on_cancel = on.bind(.close_drives),
                .on_select = on.handler(.select_drive),
                .on_refresh = on.bind(.refresh_drives),
            });
        },
        .confirm => if (state.target) |*target| try ui.one(ConfirmDialog, .{
            .drive = target,
            .image_name = if (state.image) |image| image.name() else "",
            .on_confirm = on.bind(.confirm_flash),
            .on_cancel = on.bind(.cancel_confirm),
        }),
    }
}

fn header(ui: *app.Ui) !void {
    try ui.open(null, .{ .layout = .{ .padding = .init(0, 0, 44, 0), .child_gap = 8, .child_alignment = .center } });
    defer ui.close();
    try theme.icon(ui, .flash, theme.accent, 22);
    try ui.text("OpenEtcher", theme.font(.heading, theme.header_text).with(.{ .wrap_mode = .none, .letter_spacing = 0.5 }));
}

fn stepsRow(ui: *app.Ui, state: *const State) !void {
    // centers the row in the space under the header
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .child_alignment = .center, .padding = .init(0, 0, 0, 30) } });
    defer ui.close();
    try ui.open(null, .{ .layout = .{ .child_alignment = .top_center } });
    defer ui.close();

    const on = ui.messages(App);
    const image_size = if (state.image) |image| image.size() else null;
    try ui.one(steps.ImageStep, .{
        .image = if (state.image) |*image| image else null,
        .locked = state.flashing(),
        .on_pick = on.bind(.pick_image),
        .on_remove = on.bind(.remove_image),
    });
    try steps.connector(ui, image_size != null);
    try ui.one(steps.TargetStep, .{
        .target = if (state.target) |*target| target else null,
        .enabled = state.image != null,
        .locked = state.flashing(),
        .image_size = image_size,
        .on_open = on.bind(.open_drives),
    });
    try steps.connector(ui, state.ready() or state.flashing());
    try ui.one(steps.FlashStep, .{
        .ready = state.ready(),
        .running = switch (state.flash) {
            .running => |*running| running,
            else => null,
        },
        .on_flash = on.bind(.request_flash),
        .on_cancel = on.bind(.cancel_flash),
    });
}
