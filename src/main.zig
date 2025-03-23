const std = @import("std");
const clay = @import("clay");

const platform = @import("platform.zig");
const svg = @import("svg.zig");

const colors = struct {
    const bg = clay.Color.rgb(76, 80, 91);
    const btn = clay.Color.transparent;
    const btn_text = clay.Color.white.withAlpha(170);
    const highlighted_btn = clay.Color.rgb(0, 135, 201);
    const highlighted_btn_text = clay.Color.white;
    const disabled_btn = clay.Color.rgb(55, 60, 63);
    const disabled_btn_text = clay.Color.white.withAlpha(85);

    const loading_bar_bg = clay.Color.rgb(198, 200, 189);
    const loading_bar_fg = clay.Color.rgb(39, 202, 32);
};

var disks: ?[]const platform.DeviceDescriptor = &.{
    .{
        .enumerator = .none,
        .device = "/dev/null",
        .raw = "/dev/null",
        .size = std.math.maxInt(u64),
        .is_system = true,
    },
};

const FrontPage = struct {
    override_view_state: union(enum) {
        none,
        url_input: []const u8,
        disk_input: usize,
        disk_output: []const usize,
    } = .none,
    selected_image: ?struct {
        kind: enum { file, url, disk },
        path: []const u8,
        size: usize = 0,
        real_size: usize = 0,
        compression_type: ?CompressionType = null,
        done: bool = false,

        fn ready(self: @This()) bool {
            return self.done;
        }
    } = null,
    selected_disks: ?[]const usize = null,
    mutex: std.Thread.Mutex = .{},

    current_hover_state: HoverState = .{},
    prev_hover_state: HoverState = .{},

    const HoverState = struct {
        image_from_file: bool = false,
        image_from_url: bool = false,
        image_from_disk: bool = false,
        cancel_image: bool = false,
        target_disk: bool = false,
        flash: bool = false,
    };

    var compression_type_buf: [32]u8 = undefined;
    var decompressed_size_buf: [32]u8 = undefined;

    const CompressionType = enum { none, gzip, xz, zstd };

    inline fn parentState(self: *FrontPage) *MyState {
        return @as(*MyState, @alignCast(@fieldParentPtr("front_page", self)));
    }

    fn ready(self: *const FrontPage) bool {
        if (self.selected_image) |selected_image| {
            if (!selected_image.ready()) {
                return false;
            }
        }

        return true;
    }

    const btn_text_size = 14;

    const btn_text_config: clay.TextElementConfig = .{ .font_size = btn_text_size, .text_color = colors.btn_text };
    const disabled_btn_text_config: clay.TextElementConfig = .{ .font_size = btn_text_size, .text_color = colors.disabled_btn_text };
    const highlighted_btn_text_config: clay.TextElementConfig = .{ .font_size = btn_text_size, .text_color = colors.highlighted_btn_text };

    inline fn buttonLayout(
        state: *FrontPage,
        comptime element_id_label: []const u8,
        comptime button_text: []const u8,
        button_color: clay.Color,
        label_text_config: *const clay.TextElementConfig,
        onHoverFn: ?*const clay.OnHoverFn,
    ) void {
        clay.ui()(.{
            .id = clay.id(element_id_label),
            .layout = .{
                .sizing = .{
                    .width = .grow(.{}),
                },
                .padding = .y(16),
                .child_alignment = .center,
            },
            .background_color = button_color,
            .corner_radius = .all(22),
        })({
            if (onHoverFn) |onHover| {
                clay.setOnHover(onHover, @ptrCast(state));
            }

            clay.text(button_text, label_text_config);
        });
    }

    inline fn createLayout(self: *FrontPage) void {
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
                .layout_direction = .top_to_bottom,
                .child_alignment = .center_top,
                .child_gap = 40,
            },
        })({
            clay.setOnHover(handleMouseOut, @ptrCast(self));

            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .grow(.{}) },
                    .padding = .{
                        .top = 16,
                        .bottom = 80,
                    },
                    .child_alignment = .center,
                },
            })({
                clay.text("OpenEtcher", comptime &.{ .font_size = 16, .text_color = .white });
            });

            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .grow(.{}) },
                    .child_alignment = .center,
                    .child_gap = 44,
                },
            })({
                clay.ui()(.{
                    .id = clay.id("ImageIcon"),
                    .layout = .{
                        .sizing = .fixed(60),
                        .child_alignment = .center,
                    },
                })({
                    svg.clayImage(.add_document, 10, .white, .fixed(42));
                });
                clay.ui()(.{
                    .layout = .{
                        .sizing = .{
                            .width = .fixed(100),
                            .height = .fixed(2),
                        },
                    },
                    .background_color = .rgba(255, 255, 255, 127),
                })({});
                clay.ui()(.{
                    .id = clay.id("DiskIcon"),
                    .layout = .{
                        .sizing = .fixed(60),
                        .child_alignment = .center,
                    },
                })({
                    svg.clayImage(.hdd, 10, .white, .fixed(42));
                });
                clay.ui()(.{
                    .layout = .{
                        .sizing = .{
                            .width = .fixed(100),
                            .height = .fixed(2),
                        },
                    },
                    .background_color = .rgba(255, 255, 255, 127),
                })({});
                clay.ui()(.{
                    .id = clay.id("FlashIcon"),
                    .layout = .{
                        .sizing = .fixed(60),
                        .child_alignment = .center,
                    },
                })({
                    svg.clayImage(.bolt, 10, .white, .fixed(42));
                });
            });

            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .grow(.{}) },
                    .child_alignment = .top_center,
                    .child_gap = 48,
                },
            })({
                clay.ui()(.{
                    .layout = .{
                        .sizing = .{ .width = .fixed(200) },
                        .layout_direction = .top_to_bottom,
                    },
                })({
                    const selected_image_copy = blk: {
                        self.mutex.lock();
                        defer self.mutex.unlock();

                        break :blk self.selected_image;
                    };

                    if (selected_image_copy) |selected_image| {
                        clay.ui()(.{
                            .layout = .{
                                .sizing = .{
                                    .width = .grow(.{}),
                                },
                                .padding = .y(16),
                                .child_alignment = .center,
                            },
                        })({
                            clay.text(selected_image.path[std.mem.lastIndexOfScalar(u8, selected_image.path, '/').? + 1 ..], &btn_text_config);
                        });

                        clay.ui()(.{
                            .layout = .{
                                .sizing = .{
                                    .width = .grow(.{}),
                                },
                                .padding = .y(16),
                                .child_alignment = .center,
                            },
                        })({
                            clay.ui()(.{
                                .id = clay.id("CancelImageButton"),
                            })({
                                clay.setOnHover(
                                    struct {
                                        fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                            _ = element_id;

                                            const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                            state.current_hover_state.cancel_image = true;

                                            if (pointer_data.state == .released_this_frame) {
                                                state.mutex.lock();
                                                defer state.mutex.unlock();

                                                state.selected_image = null;
                                            }
                                        }
                                    }.onHover,
                                    @ptrCast(self),
                                );
                                clay.text("Cancel", if (clay.isPointerOver(clay.id("CancelImageButton"))) comptime &.{ .font_size = 14, .text_color = colors.highlighted_btn } else &btn_text_config);
                            });
                        });

                        clay.ui()(.{
                            .layout = .{
                                .sizing = .{
                                    .width = .grow(.{}),
                                },
                                .padding = .y(16),
                                .child_alignment = .center,
                            },
                        })({
                            if (selected_image.done) {
                                clay.text(std.fmt.bufPrint(&decompressed_size_buf, "{0.2}", .{HumanizeBytes{ .bytes = @floatFromInt(selected_image.real_size) }}) catch unreachable, &btn_text_config);
                            } else {
                                clay.text(std.fmt.bufPrint(&decompressed_size_buf, "calculating size ({0.2})", .{HumanizeBytes{ .bytes = @floatFromInt(selected_image.real_size) }}) catch unreachable, &btn_text_config);
                            }
                        });

                        if (selected_image.compression_type) |compression_type| {
                            clay.ui()(.{
                                .layout = .{
                                    .sizing = .{
                                        .width = .grow(.{}),
                                    },
                                    .padding = .y(16),
                                    .child_alignment = .center,
                                },
                            })({
                                clay.text(std.fmt.bufPrint(&compression_type_buf, "compression type: {s}", .{@tagName(compression_type)}) catch unreachable, &btn_text_config);
                            });
                        }
                    } else {
                        self.buttonLayout(
                            "ImageFromFileButton",
                            "Flash from file",
                            if (self.current_hover_state.image_from_file or (!self.current_hover_state.image_from_url and !self.current_hover_state.image_from_disk)) colors.highlighted_btn else colors.btn,
                            if (self.current_hover_state.image_from_file) &highlighted_btn_text_config else &btn_text_config,
                            struct {
                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    _ = element_id;

                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                    state.current_hover_state.image_from_file = true;
                                    if (pointer_data.state == .released_this_frame) {
                                        const maybe_path = platform.selectImageFile(std.heap.page_allocator) catch unreachable;
                                        if (maybe_path) |path| {
                                            state.selected_image = .{ .kind = .file, .path = path };
                                        } else {
                                            return;
                                        }

                                        const thread = std.Thread.spawn(.{}, calculateImageSize, .{state}) catch unreachable;
                                        thread.detach();
                                    }
                                }
                            }.onHover,
                        );

                        self.buttonLayout(
                            "ImageFromURLButton",
                            "Flash from URL",
                            if (self.current_hover_state.image_from_url) colors.highlighted_btn else colors.btn,
                            if (self.current_hover_state.image_from_url) &highlighted_btn_text_config else &btn_text_config,
                            struct {
                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    _ = element_id;

                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                    state.current_hover_state.image_from_url = true;
                                    if (pointer_data.state == .released_this_frame) {
                                        // TODO: implement me
                                    }
                                }
                            }.onHover,
                        );

                        self.buttonLayout(
                            "ImageFromDiskButton",
                            "Clone a disk",
                            if (self.current_hover_state.image_from_disk) colors.highlighted_btn else colors.btn,
                            if (self.current_hover_state.image_from_disk) &highlighted_btn_text_config else &btn_text_config,
                            struct {
                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    _ = element_id;

                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                    state.current_hover_state.image_from_disk = true;
                                    if (pointer_data.state == .released_this_frame) {
                                        // TODO: implement me
                                    }
                                }
                            }.onHover,
                        );
                    }
                });

                clay.ui()(.{
                    .layout = .{
                        .sizing = .{ .width = .fixed(200) },
                        .layout_direction = .top_to_bottom,
                    },
                })({
                    self.buttonLayout(
                        "SelectTargetButton",
                        "Select Target",
                        if (self.selected_image != null and self.selected_image.?.ready() and self.selected_disks == null) colors.highlighted_btn else colors.btn,
                        if (self.selected_image != null and self.selected_image.?.ready() and self.selected_disks == null and self.current_hover_state.target_disk) &highlighted_btn_text_config else &btn_text_config,
                        struct {
                            fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                _ = element_id;

                                const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                if (state.selected_image == null or !state.selected_image.?.ready() or state.selected_disks != null) return;

                                state.current_hover_state.target_disk = true;
                                if (pointer_data.state == .released_this_frame) {
                                    state.selected_disks = &.{0};
                                }
                            }
                        }.onHover,
                    );
                });

                clay.ui()(.{
                    .layout = .{
                        .sizing = .{ .width = .fixed(200) },
                        .layout_direction = .top_to_bottom,
                    },
                })({
                    self.buttonLayout(
                        "FlashButton",
                        "Flash!",
                        if (self.selected_disks != null) colors.highlighted_btn else colors.btn,
                        if (self.selected_disks != null and self.current_hover_state.flash) &highlighted_btn_text_config else &btn_text_config,
                        struct {
                            fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                _ = element_id;

                                const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                if (state.selected_disks == null) return;

                                state.current_hover_state.flash = true;
                                if (pointer_data.state == .released_this_frame) {
                                    state.parentState().setState(.{ .flashing = .{ .total = 1000000000 } });
                                    platform.setCursor(.default);
                                }
                            }
                        }.onHover,
                    );
                });
            });
        });
    }

    fn calculateImageSize(self: *FrontPage) !void {
        self.mutex.lock();
        if (self.selected_image == null) {
            self.mutex.unlock();
            return;
        }

        defer self.parentState().redraw();

        const file, self.selected_image.?.size = switch (self.selected_image.?.kind) {
            .file => blk: {
                errdefer self.mutex.unlock();
                const file = try std.fs.openFileAbsolute(self.selected_image.?.path, .{});
                const stat = try file.stat();

                break :blk .{ file, stat.size };
            },
            .url => std.debug.panic("not implemented", .{}),
            .disk => std.debug.panic("not implemented", .{}),
        };
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        var hack_buf: [0]u8 = undefined; // hack to peek
        _ = br.read(&hack_buf) catch |err| {
            self.mutex.unlock();
            return err;
        };

        if (std.mem.startsWith(u8, &br.buf, &.{ 0x1f, 0x8b })) {
            self.selected_image.?.compression_type = .gzip;
            self.mutex.unlock();

            self.parentState().redraw();

            var d = std.compress.gzip.decompressor(br.reader());
            while (try d.next()) |bytes| {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.selected_image) |*selected_image| {
                    selected_image.real_size += bytes.len;
                } else {
                    std.debug.print("image size calculation cancelled\n", .{});
                    return;
                }

                self.parentState().redraw();
            }
        } else if (std.mem.startsWith(u8, &br.buf, &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) {
            self.selected_image.?.compression_type = .xz;
            self.mutex.unlock();

            self.parentState().redraw();

            var d = try std.compress.xz.decompress(std.heap.page_allocator, br.reader());
            defer d.deinit();

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try d.read(&buf);

                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.selected_image) |*selected_image| {
                    selected_image.real_size += n;
                } else {
                    std.debug.print("image size calculation cancelled\n", .{});
                    return;
                }

                self.parentState().redraw();
            }
        } else if (std.mem.startsWith(u8, &br.buf, &.{ 0x28, 0xb5, 0x2f, 0xfd })) {
            self.selected_image.?.compression_type = .zstd;
            self.mutex.unlock();

            self.parentState().redraw();

            var window_buf: [std.compress.zstd.DecompressorOptions.default_window_buffer_len]u8 = undefined;
            var d = std.compress.zstd.decompressor(br.reader(), .{ .window_buffer = &window_buf, .verify_checksum = false });

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try d.read(&buf);

                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.selected_image) |*selected_image| {
                    selected_image.real_size += n;
                } else {
                    std.debug.print("image size calculation cancelled\n", .{});
                    return;
                }

                self.parentState().redraw();
            }
        } else {
            // assume image is not compressed
            if (self.selected_image) |*selected_image| {
                selected_image.real_size += selected_image.size;
            }
            self.mutex.unlock();
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.selected_image) |*selected_image| {
            selected_image.done = true;
        }
    }

    fn handleMouseOut(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
        _ = element_id;
        _ = pointer_data;

        const state: *FrontPage = @alignCast(@ptrCast(user_data));
        if (!std.mem.eql(u8, std.mem.asBytes(&state.prev_hover_state), std.mem.asBytes(&state.current_hover_state))) {
            state.parentState().redraw();
            if (std.mem.eql(u8, std.mem.asBytes(&state.current_hover_state), std.mem.asBytes(&HoverState{}))) {
                platform.setCursor(.default);
            } else {
                platform.setCursor(.pointer);
            }
        }

        state.prev_hover_state = state.current_hover_state;
        state.current_hover_state = .{};
    }
};

const HumanizeBytes = struct {
    bytes: f64,

    const units = [_][]const u8{
        "B",
        "KB",
        "MB",
        "GB",
        "TB",
        "PB",
        "EB",
    };

    pub fn format(self: HumanizeBytes, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const unit, const num = blk: {
            if (!std.math.isNormal(self.bytes)) {
                break :blk .{ units[0], @as(f64, 0.0) };
            }
            inline for (units, 0..) |unit, i| {
                const magnitude = comptime std.math.pow(f64, 1000, i);
                if (self.bytes < magnitude * 1000 or i == units.len - 1) {
                    break :blk .{ unit, self.bytes / magnitude };
                }
            }
        };

        try std.fmt.format(writer, "{d:" ++ fmt ++ "}{s}", .{ num, unit });
    }
};

const HumanizeDuration = struct {
    seconds: f64,

    pub fn format(self: HumanizeDuration, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const unit, const num = blk: {
            if (!std.math.isNormal(self.seconds)) {
                break :blk .{ "s", @as(f64, 0.0) };
            }

            if (self.seconds < 0.000001) {
                break :blk .{ "ns", self.seconds / 1000000000.0 };
            }

            if (self.seconds < 0.001) {
                break :blk .{ "us", self.seconds / 1000000.0 };
            }

            if (self.seconds < 1) {
                break :blk .{ "ms", self.seconds / 1000.0 };
            }

            if (self.seconds < 60) {
                break :blk .{ "seconds", self.seconds };
            }

            if (self.seconds < 3600) {
                break :blk .{ "minutes", self.seconds / 60.0 };
            }

            if (self.seconds < 86400) {
                break :blk .{ "hours", self.seconds / 3600.0 };
            }

            break :blk .{ "days", self.seconds / 86400.0 };
        };

        try std.fmt.format(writer, "{d:" ++ fmt ++ "} {s}", .{ num, unit });
    }
};

const Flashing = struct {
    total: usize,
    mu: std.Thread.Mutex = .{},
    current: usize = 0,

    rates: [32]f64 = [_]f64{0} ** 32,
    rates_pos: usize = 0,
    rates_len: usize = 0,

    var percentage_buf: [8]u8 = undefined;
    var rate_buf: [16]u8 = undefined;
    var eta_buf: [32]u8 = undefined;

    inline fn parentState(self: *Flashing) *MyState {
        return @as(*MyState, @fieldParentPtr("flashing", self));
    }

    fn doflash(self: *Flashing) void {
        const rate_interval = 1000;

        // TODO: replace with real implementation
        var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
        const rand = rng.random();
        var current: usize = 0;
        var start = std.time.milliTimestamp();
        var last_progress: usize = 0;
        while (current < self.total) {
            const now = std.time.milliTimestamp();

            current += rand.intRangeAtMost(usize, 0, @min(self.total / 500, self.total - current));

            {
                self.mu.lock();
                defer self.mu.unlock();
                self.current = current;

                const dt = now - start;
                if (dt >= rate_interval) {
                    start = now;

                    const delta = current - last_progress;
                    last_progress = current;

                    self.rates[self.rates_pos] = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(dt)) * 1000.0;
                    self.rates_len = @min(self.rates_len + 1, self.rates.len);
                    self.rates_pos = (self.rates_pos + 1) % self.rates.len;
                }
            }

            self.parentState().redraw();
            std.Thread.sleep(10000000);
        }
    }

    fn onSwap(self: *Flashing, old_state: MyState) !void {
        _ = old_state;
        const thread = try std.Thread.spawn(.{}, doflash, .{self});
        thread.detach();
    }

    inline fn createLayout(state: *Flashing) void {
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
                .layout_direction = .top_to_bottom,
                .child_alignment = .center_top,
                .child_gap = 40,
            },
        })({
            clay.ui()(.{
                .layout = .{
                    .sizing = .{ .width = .grow(.{}) },
                    .padding = .{
                        .top = 16,
                        .bottom = 80,
                    },
                    .child_alignment = .center_top,
                },
            })({
                clay.text("flashing", comptime &.{ .font_size = 16, .text_color = .white });
            });

            const percent, const rate, const eta = blk: {
                state.mu.lock();
                defer state.mu.unlock();

                var rates_sum: f64 = 0;
                for (0..state.rates_len) |i| {
                    rates_sum += state.rates[i];
                }

                const rate = if (state.rates_len == 0) @as(f64, 0.0) else rates_sum / @as(f64, @floatFromInt(state.rates_len));

                break :blk .{
                    if (state.total == 0) 0 else @as(f64, @floatFromInt(state.current)) / @as(f64, @floatFromInt(state.total)),
                    rate,
                    @as(f64, @floatFromInt(state.total - state.current)) / rate,
                };
            };

            clay.ui()(.{
                .id = clay.id("ProgressBar"),
                .layout = .{
                    .sizing = .{ .width = .fixed(400), .height = .fixed(48) },
                },
                .background_color = colors.loading_bar_bg,
            })({
                clay.ui()(.{
                    .layout = .{
                        .sizing = .{ .width = .percent(@floatCast(percent)), .height = .grow(.{}) },
                    },
                    .background_color = colors.loading_bar_fg,
                })({});

                clay.ui()(.{
                    .floating = .{
                        .attach_points = .both(.center),
                        .attach_to = .parent,
                    },
                })({
                    clay.text(std.fmt.bufPrint(&percentage_buf, "{d:0.2}%", .{percent * 100.0}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
                });
            });

            clay.text(std.fmt.bufPrint(&rate_buf, "{0.2}/s", .{HumanizeBytes{ .bytes = rate }}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });

            if (percent == 1) {
                clay.text("done", comptime &.{ .font_size = 16, .text_color = .white });
            } else if (rate == 0 or state.total == 0) {
                clay.text("calculating eta", comptime &.{ .font_size = 16, .text_color = .white });
            } else {
                clay.text(std.fmt.bufPrint(&eta_buf, "{0.0} remaining", .{HumanizeDuration{ .seconds = eta }}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
            }
        });
    }
};

const MyState = union(enum) {
    front_page: FrontPage,
    flashing: Flashing,

    pub const default: MyState = .{ .front_page = .{} };

    inline fn redraw(self: *const MyState) void {
        app.redraw(self);
    }

    fn setState(self: *MyState, new_state: MyState) void {
        const old_state = self.*;
        self.* = new_state;

        switch (self.*) {
            inline else => |*inner_state| if (@hasDecl(@TypeOf(inner_state.*), "onSwap")) inner_state.onSwap(old_state) catch unreachable,
        }
    }

    inline fn createLayout(self: *MyState) void {
        switch (self.*) {
            inline else => |*inner_state| inner_state.createLayout(),
        }
    }
};

pub fn createLayout(state: *MyState) clay.RenderCommandArray {
    return clay.layout()({
        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
            },
            .background_color = colors.bg,
        })({
            state.createLayout();
        });
    });
}

const app = platform.App(
    MyState,
    createLayout,
);

pub fn main() !void {
    app.run();
}

test "drivelist" {
    const devices = try platform.listStorageDevices(std.testing.allocator);
    defer {
        for (devices) |device| {
            device.deinit(std.testing.allocator);
        }

        std.testing.allocator.free(devices);
    }

    // for (devices) |device| {
    //     std.debug.print("device: {s} {?s} {?s} {?s}\n", .{ device.device, device.device_path, device.bus_type, device.description });
    // }
}

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("svg.zig");
}
