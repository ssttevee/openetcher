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

    const system_disk_warning = clay.Color.rgb(218, 165, 32);

    const loading_bar_bg = clay.Color.rgb(198, 200, 189);
    const loading_bar_fg = clay.Color.rgb(39, 202, 32);
};

var http_client: std.http.Client = .{ .allocator = std.heap.page_allocator };

const ImageType = enum {
    file,
    url,
    disk,

    const Source = union(ImageType) {
        file: std.fs.File,
        url: std.http.Client.Request,
        disk: std.fs.File,

        fn size(self: *Source) !?usize {
            return switch (self.*) {
                inline .file, .disk => |*file| (try file.stat()).size,
                .url => |*req| req.response.content_length,
            };
        }

        fn deinit(self: *Source) void {
            switch (self.*) {
                inline .file, .disk => |file| file.close(),
                .url => |*req| req.deinit(),
            }
        }

        const Error = std.fs.File.Reader.Error || std.http.Client.Request.Reader.Error;

        fn read(self: *Source, buf: []u8) Error!usize {
            return switch (self.*) {
                inline .file, .disk => |file| file.read(buf),
                .url => |*req| req.read(buf),
            };
        }

        const Reader = std.io.Reader(*Source, Error, read);

        fn reader(self: *Source) Reader {
            return .{ .context = self };
        }
    };

    fn open(self: ImageType, path: []const u8) !Source {
        switch (self) {
            inline .file, .disk => |tag| {
                return @unionInit(Source, @tagName(tag), try std.fs.openFileAbsolute(path, .{}));
            },
            .url => {
                var buf: [8192]u8 = undefined;
                var req = try http_client.open(.GET, try .parse(path), .{ .server_header_buffer = &buf });
                try req.send();
                try req.finish();
                try req.wait();
                return .{ .url = req };
            },
        }
    }
};
const CompressionType = enum {
    none,
    gzip,
    xz,
    zstd,

    fn fromLeadingBytes(bytes: []const u8) CompressionType {
        if (std.mem.startsWith(u8, bytes, &.{ 0x1f, 0x8b })) {
            return .gzip;
        }

        if (std.mem.startsWith(u8, bytes, &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) {
            return .xz;
        }

        if (std.mem.startsWith(u8, bytes, &.{ 0x28, 0xb5, 0x2f, 0xfd })) {
            return .zstd;
        }

        return .none;
    }

    fn Decompressor(InternalReader: type) type {
        return union(CompressionType) {
            none: InternalReader,
            gzip: std.compress.gzip.Decompressor(InternalReader),
            xz: std.compress.xz.Decompress(InternalReader),
            zstd: std.compress.zstd.Decompressor(InternalReader),

            fn deinit(self: *@This()) void {
                switch (self.*) {
                    .none, .gzip => {},
                    .xz => |*xz| xz.deinit(),
                    .zstd => |*zstd| std.heap.page_allocator.free(zstd.buffer.data),
                }
            }

            const Error = InternalReader.Error || std.compress.gzip.Decompressor(InternalReader).Error || std.compress.xz.Decompress(InternalReader).Error || std.compress.zstd.Decompressor(InternalReader).Error;

            fn read(self: *@This(), buf: []u8) Error!usize {
                return switch (self.*) {
                    inline else => |*r| r.read(buf),
                };
            }

            pub const Reader = std.io.Reader(*@This(), Error, read);

            fn reader(self: *@This()) Reader {
                return .{ .context = self };
            }
        };
    }

    fn decompressor(self: CompressionType, reader: anytype) !Decompressor(@TypeOf(reader)) {
        return switch (self) {
            .none => .{ .none = reader },
            .gzip => .{ .gzip = std.compress.gzip.decompressor(reader) },
            .xz => .{ .xz = try std.compress.xz.decompress(std.heap.page_allocator, reader) },
            .zstd => .{
                .zstd = std.compress.zstd.decompressor(
                    reader,
                    .{
                        .window_buffer = try std.heap.page_allocator.alloc(
                            u8,
                            std.compress.zstd.DecompressorOptions.default_window_buffer_len,
                        ),
                        .verify_checksum = false,
                    },
                ),
            },
        };
    }
};

var disks_mutex: std.Thread.Mutex = .{};
var disks: ?[]const platform.DeviceDescriptor = null;

const FrontPage = struct {
    override_view_state: union(enum) {
        none,
        url_input: []const u8,
        disk_input: usize,
        disk_output: []const usize,
    } = .none,
    selected_image: ?struct {
        kind: ImageType,
        path: []const u8,
        size: usize = 0,
        real_size: usize = 0,
        compression_type: ?CompressionType = null,
        done: bool = false,

        fn ready(self: @This()) bool {
            return self.done;
        }
    } = null,
    selected_disks: std.StaticBitSet(64) = .initEmpty(), // use as flags, only support up to 64 bits
    show_system_disks: bool = false,
    prev_show_system_disks: bool = false,
    mutex: std.Thread.Mutex = .{},

    current_hover_state: HoverState = .{},
    prev_hover_state: HoverState = .{},

    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    const HoverState = struct {
        image_from_file: bool = false,
        image_from_url: bool = false,
        image_from_disk: bool = false,
        cancel_image: bool = false,
        flash: bool = false,
        target_disk_index: ?usize = null,
        show_system_disks: bool = false,
        reload_disks: bool = false,
        expand_disks: bool = false,
    };

    inline fn parentState(self: *FrontPage) *MyState {
        return @as(*MyState, @fieldParentPtr("view", @as(*MyState.View, @fieldParentPtr("front_page", self))));
    }

    fn ready(self: *const FrontPage) bool {
        if (self.selected_image) |selected_image| {
            if (!selected_image.ready()) {
                return false;
            }
        }

        return true;
    }

    fn deinit(self: *const FrontPage) void {
        self.arena.deinit();
    }

    const btn_text_size = 14;

    const selector_text_config: clay.TextElementConfig = .{ .font_size = btn_text_size, .text_color = .black };
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
        _ = self.arena.reset(.retain_capacity);

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
                                clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:0.2}", .{HumanizeBytes.init(selected_image.real_size)}) catch unreachable, &btn_text_config);
                            } else {
                                clay.text(std.fmt.allocPrint(self.arena.allocator(), "calculating size ({d:0.2})", .{HumanizeBytes.init(selected_image.real_size)}) catch unreachable, &btn_text_config);
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
                                clay.text(std.fmt.allocPrint(self.arena.allocator(), "compression type: {s}", .{@tagName(compression_type)}) catch unreachable, &btn_text_config);
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
                        .layout_direction = .top_to_bottom,
                    },
                })({
                    clay.ui()(.{
                        .floating = .{
                            .offset = .{ .y = -8 },
                            .attach_points = .{
                                .element = .bottom_left,
                                .parent = .top_left,
                            },
                            .attach_to = .parent,
                        },
                    })({
                        clay.setOnHover(
                            struct {
                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));

                                    state.current_hover_state.reload_disks = true;

                                    if (pointer_data.state == .released_this_frame) {
                                        state.reloadDiskList() catch |err| {
                                            std.debug.print("failed to reload disk list: {}\n", .{err});
                                            return;
                                        };
                                        state.parentState().redraw();
                                    }

                                    handleMouseOut(element_id, pointer_data, user_data);
                                }
                            }.onHover,
                            @ptrCast(self),
                        );
                        clay.text("reload", if (self.prev_hover_state.reload_disks) &highlighted_btn_text_config else &btn_text_config);
                    });

                    clay.ui()(.{
                        .floating = .{
                            .offset = .{ .y = -8 },
                            .attach_points = .{
                                .element = .bottom_right,
                                .parent = .top_right,
                            },
                            .attach_to = .parent,
                        },
                    })({
                        clay.setOnHover(
                            struct {
                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));

                                    state.current_hover_state.expand_disks = true;

                                    if (pointer_data.state == .released_this_frame) {
                                        // TODO: implement me
                                        // state.parentState().redraw();
                                    }

                                    handleMouseOut(element_id, pointer_data, user_data);
                                }
                            }.onHover,
                            @ptrCast(self),
                        );
                        clay.text("expand", if (self.prev_hover_state.expand_disks) &highlighted_btn_text_config else &btn_text_config);
                    });

                    var has_system_disk = false;
                    clay.ui()(.{
                        .layout = .{
                            .sizing = .{
                                .width = .fixed(200),
                                .height = .fixed(170),
                            },
                            .layout_direction = .top_to_bottom,
                        },
                        .background_color = clay.Color.white.withAlpha(220),
                        .border = .{
                            .width = .outside(2),
                            .color = clay.Color.black.withAlpha(100),
                        },
                    })({
                        const disks_copy = blk: {
                            disks_mutex.lock();
                            defer disks_mutex.unlock();

                            break :blk disks;
                        };

                        if (disks_copy) |devices| {
                            clay.ui()(.{
                                .id = clay.id("TargetDiskSelector"),
                                .layout = .{
                                    .sizing = .{
                                        .width = .grow(.{}),
                                    },
                                    .layout_direction = .top_to_bottom,
                                },
                                .scroll = .{ .vertical = true },
                            })({
                                for (devices, 0..) |*disk, i| {
                                    if (disk.is_system) {
                                        has_system_disk = true;
                                        if (!self.show_system_disks) {
                                            break;
                                        }
                                    }

                                    clay.ui()(.{
                                        .id = clay.idi("TargetDiskOption", @intCast(i)),
                                        .layout = .{
                                            .sizing = .{
                                                .width = .grow(.{}),
                                            },
                                            .child_alignment = .left_center,
                                            .padding = .all(12),
                                            .child_gap = 12,
                                        },
                                        .background_color = if (self.current_hover_state.target_disk_index == i) clay.Color.black.withAlpha(60) else .{},
                                    })({
                                        clay.setOnHover(
                                            struct {
                                                fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                                    const state: *FrontPage = @alignCast(@ptrCast(user_data));

                                                    const selector_data = clay.getElementData(clay.id("TargetDiskSelector")) orelse return;
                                                    if (!selector_data.bounding_box.contains(pointer_data.position)) return;

                                                    state.current_hover_state.target_disk_index = element_id.offset;

                                                    if (pointer_data.state == .released_this_frame) {
                                                        state.selected_disks.toggle(element_id.offset);
                                                        state.parentState().redraw();
                                                    }
                                                }
                                            }.onHover,
                                            @ptrCast(self),
                                        );

                                        clay.ui()(.{
                                            .layout = .{
                                                .sizing = .fixed(14),
                                                .child_alignment = .center,
                                            },
                                            .border = .{
                                                .width = .outside(2),
                                                .color = .black,
                                            },
                                        })({
                                            if (self.selected_disks.isSet(i)) {
                                                clay.ui()(.{
                                                    .layout = .{
                                                        .sizing = .fixed(8),
                                                    },
                                                    .background_color = .black,
                                                })({});
                                            }
                                        });

                                        clay.text(disk.device, &selector_text_config);

                                        clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});

                                        clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:3.1}", .{HumanizeBytes.init(disk.size * disk.block_size)}) catch unreachable, &selector_text_config);

                                        clay.ui()(.{
                                            .layout = .{
                                                .sizing = .fixed(10),
                                                .child_alignment = .center,
                                                .padding = .x(3),
                                            },
                                            .background_color = if (disk.is_system) colors.system_disk_warning else .{},
                                            .corner_radius = .all(2),
                                        })({});
                                    });
                                }
                            });
                        } else {
                            clay.ui()(.{
                                .layout = .{
                                    .sizing = .{
                                        .width = .grow(.{}),
                                    },
                                    .padding = .y(16),
                                    .child_alignment = .center,
                                },
                            })({
                                clay.text("loading disks...", &selector_text_config);
                            });
                        }
                    });

                    if (has_system_disk) {
                        // not sure when this would be false tbh...

                        clay.ui()(.{})({
                            clay.setOnHover(
                                struct {
                                    fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                        _ = element_id;

                                        const state: *FrontPage = @alignCast(@ptrCast(user_data));

                                        state.current_hover_state.show_system_disks = true;

                                        if (pointer_data.state == .released_this_frame) {
                                            state.show_system_disks = !state.show_system_disks;
                                            state.parentState().redraw();
                                        }
                                    }
                                }.onHover,
                                @ptrCast(self),
                            );
                            if (self.show_system_disks) {
                                clay.text("hide system disks", if (self.current_hover_state.show_system_disks) &highlighted_btn_text_config else &btn_text_config);
                            } else {
                                clay.text("show system disks", if (self.current_hover_state.show_system_disks) &highlighted_btn_text_config else &btn_text_config);
                            }
                        });
                    }
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
                        if (self.selected_image != null and self.selected_image.?.ready() and self.selected_disks.count() != 0) colors.highlighted_btn else colors.btn,
                        if (self.selected_image != null and self.selected_image.?.ready() and self.selected_disks.count() != 0 and self.current_hover_state.flash) &highlighted_btn_text_config else &btn_text_config,
                        struct {
                            fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                _ = element_id;

                                const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                if (state.selected_disks.count() == 0) return;
                                if (state.selected_image) |*img| {
                                    if (!img.ready()) return;

                                    state.current_hover_state.flash = true;
                                    if (img.compression_type) |compression_type| {
                                        if (pointer_data.state == .released_this_frame and img.done) {
                                            state.parentState().setState(.{
                                                .flashing = Flashing.init(
                                                    img.kind,
                                                    img.path,
                                                    img.real_size,
                                                    compression_type,
                                                    state.selected_disks,
                                                ) catch unreachable,
                                            });
                                            platform.setCursor(.default);
                                        }
                                    }
                                }
                            }
                        }.onHover,
                    );
                });
            });
        });

        if (self.prev_show_system_disks != self.show_system_disks) {
            self.prev_show_system_disks = self.show_system_disks;
            self.parentState().fixScroll();
        }
    }

    fn onMount(self: *FrontPage) !void {
        try self.reloadDiskList();
    }

    fn reloadDiskList(self: *FrontPage) !void {
        {
            disks_mutex.lock();
            defer disks_mutex.unlock();

            if (disks) |prev| {
                for (prev) |device| {
                    if (std.mem.eql(u8, "/dev/null", device.device)) {
                        continue;
                    }

                    device.deinit(std.heap.page_allocator);
                }

                std.heap.page_allocator.free(prev);
            }

            disks = null;
        }

        const thread = try std.Thread.spawn(.{}, loadDiskList, .{ self, std.heap.page_allocator });
        thread.detach();
    }

    fn loadDiskList(self: *FrontPage, allocator: std.mem.Allocator) !void {
        const devices = try platform.listStorageDevices(allocator);
        defer allocator.free(devices);

        std.mem.sortUnstable(
            platform.DeviceDescriptor,
            devices,
            {},
            struct {
                fn lessThan(_: void, lhs: platform.DeviceDescriptor, rhs: platform.DeviceDescriptor) bool {
                    if (lhs.is_system != rhs.is_system) {
                        return !lhs.is_system;
                    }

                    return std.ascii.lessThanIgnoreCase(lhs.device, rhs.device);
                }
            }.lessThan,
        );

        const devices_with_devnull = try allocator.alloc(platform.DeviceDescriptor, devices.len + 1);
        devices_with_devnull[0] = .{
            .enumerator = .none,
            .device = "/dev/null",
            .raw = "/dev/null",
            .size = std.math.maxInt(u64) / 512,
            .is_virtual = true,
        };

        @memcpy(devices_with_devnull[1..], devices);

        disks_mutex.lock();
        defer disks_mutex.unlock();

        disks = devices_with_devnull;

        self.parentState().redraw();
    }

    fn calculateImageSize(self: *FrontPage) !void {
        var source, const compression_type, var br = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.selected_image) |*img| {
                var source = try img.kind.open(img.path);
                errdefer source.deinit();

                std.debug.print("stat\n", .{});
                img.size = (try source.size()) orelse 0;

                var br = std.io.bufferedReader(source.reader());
                var hack_buf: [0]u8 = undefined; // hack to peek
                _ = try br.read(&hack_buf);

                const compression_type = CompressionType.fromLeadingBytes(&br.buf);
                img.compression_type = compression_type;
                if (compression_type == .none) {
                    img.real_size = img.size;
                }

                break :blk .{ source, compression_type, br };
            } else {
                return;
            }
        };

        defer source.deinit();

        self.parentState().redraw();

        // source ptr may have changed, set it again just in case
        br.unbuffered_reader = source.reader();

        switch (compression_type) {
            .none => {},
            else => {
                var d = try compression_type.decompressor(br.reader().any());
                defer d.deinit();

                defer self.parentState().redraw();

                var dr = d.reader();
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = try dr.read(&buf);
                    if (n == 0) {
                        break;
                    }

                    {
                        self.mutex.lock();
                        defer self.mutex.unlock();

                        if (self.selected_image) |*selected_image| {
                            selected_image.real_size += n;
                        } else {
                            std.debug.print("image size calculation canceled\n", .{});
                            return;
                        }
                    }

                    self.parentState().redraw();
                }
            },
        }

        defer self.parentState().redraw();

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
    bytes: usize,

    pub fn init(bytes: usize) HumanizeBytes {
        return .{ .bytes = bytes };
    }

    const units = [_][]const u8{
        "KB",
        "MB",
        "GB",
        "TB",
        "PB",
        "EB",
    };

    pub fn format(self: HumanizeBytes, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.bytes < 1000) {
            try std.fmt.formatType(self.bytes, fmt, options, writer, 1);
            try writer.writeByte('B');
            return;
        }

        const unit, const num = blk: {
            inline for (units[0 .. units.len - 1], 0..) |unit, i| {
                const magnitude = comptime std.math.powi(usize, 1000, i + 1) catch unreachable;
                if (self.bytes / magnitude < 1000) {
                    break :blk .{ unit, @as(f64, @floatFromInt(self.bytes)) / @as(f64, @floatFromInt(magnitude)) };
                }
            }

            break :blk .{ units[units.len - 1], @as(f64, @floatFromInt(self.bytes)) / comptime std.math.pow(f64, 1000, units.len) };
        };

        try std.fmt.formatType(num, fmt, options, writer, 1);
        try writer.writeAll(unit);
    }
};

const HumanizeDuration = struct {
    seconds: f64,

    pub fn format(self: HumanizeDuration, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
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

        try std.fmt.formatType(num, fmt, options, writer, 1);
        try writer.writeByte(' ');
        try writer.writeAll(unit);
    }
};

fn TimedReader(Reader: type) type {
    return struct {
        internal_reader: Reader,
        accumulated_nanos: usize = 0,

        fn read(self: *@This(), buf: []u8) Reader.Error!usize {
            const start = std.time.nanoTimestamp();
            defer {
                const d = std.time.nanoTimestamp() - start;
                self.accumulated_nanos += @intCast(d);
            }

            return try self.internal_reader.read(buf);
        }

        fn reader(self: *@This()) std.io.Reader(*@This(), Reader.Error, read) {
            return .{ .context = self };
        }
    };
}

fn timedReader(reader: anytype) TimedReader(@TypeOf(reader)) {
    return .{ .internal_reader = reader };
}

const Flashing = struct {
    source: ImageType.Source,
    compression_type: CompressionType,
    target_disks: []*const platform.DeviceDescriptor,
    total: usize,
    mu: std.Thread.Mutex = .{},
    current: usize = 0,

    rates: [32]f64 = [_]f64{0} ** 32,
    rates_pos: usize = 0,
    rates_len: usize = 0,

    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    inline fn parentState(self: *Flashing) *MyState {
        return @as(*MyState, @fieldParentPtr("view", @as(*MyState.View, @fieldParentPtr("flashing", self))));
    }

    fn init(kind: ImageType, path: []const u8, real_size: usize, compression_type: CompressionType, selected_disks: std.StaticBitSet(64)) !Flashing {
        const loaded_disks = disks orelse return error.DisksNotLoaded;

        const source = try kind.open(path);
        const target_disks = try std.heap.page_allocator.alloc(*const platform.DeviceDescriptor, selected_disks.count());

        var it = selected_disks.iterator(.{});
        var j: usize = 0;
        while (it.next()) |i| {
            std.debug.assert(loaded_disks.len > i);

            target_disks[j] = &loaded_disks[i];
            j += 1;
        }

        return .{
            .source = source,
            .compression_type = compression_type,
            .total = real_size,
            .target_disks = target_disks,
        };
    }

    fn deinit(self: *Flashing) void {
        std.heap.page_allocator.free(self.target_disks);
        self.source.deinit();
        self.arena.deinit();
    }

    fn targetDisksBlockSizeLCM(self: *const Flashing) !usize {
        std.debug.assert(self.target_disks.len > 0);

        if (self.target_disks.len == 1) {
            return self.target_disks[0].block_size;
        }

        const block_sizes = blk: {
            var block_sizes: std.AutoArrayHashMapUnmanaged(u32, void) = .{};
            defer block_sizes.deinit(std.heap.page_allocator);

            try block_sizes.ensureUnusedCapacity(std.heap.page_allocator, self.target_disks.len);

            for (self.target_disks) |disk| {
                block_sizes.putAssumeCapacity(disk.block_size, {});
            }

            break :blk try std.heap.page_allocator.dupe(u32, block_sizes.keys());
        };
        defer std.heap.page_allocator.free(block_sizes);

        if (block_sizes.len == 1) {
            return block_sizes[0];
        }

        const multiples = try std.heap.page_allocator.dupe(u32, block_sizes);
        defer std.heap.page_allocator.free(multiples);

        while (!std.mem.allEqual(u32, multiples[1..], multiples[0])) {
            const max = std.mem.max(u32, multiples);
            for (block_sizes, multiples) |block_size, *multiple| {
                if (multiple.* < max) {
                    multiple.* += block_size;
                }
            }
        }

        return multiples[0];
    }

    fn doflash(self: *Flashing) !void {
        const rate_interval = 1000000000; // at least 1s between each rate update

        var current: usize = 0;
        var io_tr = timedReader(self.source.reader());
        var dcompressor = try self.compression_type.decompressor(io_tr.reader());
        var dc_tr = timedReader(dcompressor.reader());

        // 65536 seems to be the largest block size people would consider using
        var br = std.io.bufferedReaderSize(65536, dc_tr.reader());
        const block_size_lcm = try self.targetDisksBlockSizeLCM();
        std.debug.assert(br.buf.len > block_size_lcm);

        const r = br.reader();

        const buf = try std.heap.page_allocator.alloc(u8, block_size_lcm);
        defer std.heap.page_allocator.free(buf);

        var disk_files_len: usize = 0;
        const disk_files = try std.heap.page_allocator.alloc(std.fs.File, self.target_disks.len);
        defer {
            for (0..disk_files_len) |i| {
                disk_files[i].close();
            }

            std.heap.page_allocator.free(disk_files);
        }

        for (self.target_disks) |disk| {
            disk_files[disk_files_len] = try std.fs.openFileAbsolute(disk.device, .{ .mode = .write_only, .lock = .exclusive });
            disk_files_len += 1;
        }

        const disk_write_times = try std.heap.page_allocator.alloc(i128, self.target_disks.len);
        defer std.heap.page_allocator.free(disk_write_times);

        var start = std.time.nanoTimestamp();
        var last_progress: usize = 0;
        while (current < self.total) {
            const n = try r.readAll(buf);

            for (self.target_disks, disk_files, 0..) |disk, file, i| {
                // TODO: optimize with io uring
                const write_start = std.time.nanoTimestamp();
                for (0..@as(usize, @intCast(std.math.divCeil(usize, n, disk.block_size) catch unreachable))) |j| {
                    try file.writeAll(buf[j * disk.block_size .. @min(n, (j + 1) * disk.block_size)]);
                }
                disk_write_times[i] += std.time.nanoTimestamp() - write_start;
            }

            current += n;

            const now = std.time.nanoTimestamp();

            {
                self.mu.lock();
                defer self.mu.unlock();
                self.current = current;

                const dt = now - start;
                if (dt >= rate_interval) {
                    start = now;

                    const delta = current - last_progress;
                    last_progress = current;

                    self.rates[self.rates_pos] = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(dt)) * 1000000000.0;
                    self.rates_len = @min(self.rates_len + 1, self.rates.len);
                    self.rates_pos = (self.rates_pos + 1) % self.rates.len;

                    var total_us = @as(f64, @floatFromInt(dc_tr.accumulated_nanos));
                    for (disk_write_times) |write_us| {
                        total_us += @as(f64, @floatFromInt(write_us));
                    }

                    std.debug.print("read time: {d:0.1}%, decompression time: {d:0.1}%", .{ @as(f64, @floatFromInt(io_tr.accumulated_nanos)) / total_us * 100, @as(f64, @floatFromInt(dc_tr.accumulated_nanos - io_tr.accumulated_nanos)) / total_us * 100 });
                    for (self.target_disks, disk_write_times) |disk, *write_us| {
                        std.debug.print(", {s} write time: {d:0.1}%", .{ disk.device, @as(f64, @floatFromInt(write_us.*)) / total_us * 100 });
                        write_us.* = 0;
                    }
                    std.debug.print("\n", .{});
                    io_tr.accumulated_nanos = 0;
                    dc_tr.accumulated_nanos = 0;
                }
            }

            self.parentState().redraw();
        }
    }

    fn onMount(self: *Flashing) !void {
        const thread = try std.Thread.spawn(.{}, doflash, .{self});
        thread.detach();
    }

    inline fn createLayout(self: *Flashing) void {
        _ = self.arena.reset(.retain_capacity);

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
                self.mu.lock();
                defer self.mu.unlock();

                var rates_sum: f64 = 0;
                for (0..self.rates_len) |i| {
                    rates_sum += self.rates[i];
                }

                const rate = if (self.rates_len == 0) @as(f64, 0.0) else rates_sum / @as(f64, @floatFromInt(self.rates_len));

                break :blk .{
                    if (self.total == 0) 0 else @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total)),
                    rate,
                    @as(f64, @floatFromInt(self.total - self.current)) / rate,
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
                    clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:3.1}%", .{percent * 100.0}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
                });
            });

            clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:3.2}/s", .{HumanizeBytes.init(@intFromFloat(rate))}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });

            if (percent == 1) {
                clay.text("done", comptime &.{ .font_size = 16, .text_color = .white });
            } else if (rate == 0 or self.total == 0) {
                clay.text("calculating eta", comptime &.{ .font_size = 16, .text_color = .white });
            } else {
                clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:0.0} remaining", .{HumanizeDuration{ .seconds = eta }}) catch unreachable, comptime &.{ .font_size = 16, .text_color = .white });
            }
        });
    }
};

const MyState = struct {
    const View = union(enum) {
        front_page: FrontPage,
        flashing: Flashing,
    };

    view: View = .{ .front_page = .{} },

    pub const default: MyState = .{};

    const redraw = app.redraw;

    pub fn setState(self: *MyState, new_view: View) void {
        switch (self.view) {
            inline else => |*inner_state| if (@hasDecl(@TypeOf(inner_state.*), "deinit")) inner_state.deinit(),
        }

        self.view = new_view;

        switch (self.view) {
            inline else => |*inner_state| if (@hasDecl(@TypeOf(inner_state.*), "onMount")) inner_state.onMount() catch unreachable,
        }
    }

    pub fn onFirstDraw(self: *MyState) void {
        switch (self.view) {
            inline else => |*inner_state| if (@hasDecl(@TypeOf(inner_state.*), "onMount")) inner_state.onMount() catch unreachable,
        }
    }

    // Fix scroll position after the contents shrink to scroll back to the content.
    inline fn fixScroll(self: *MyState) void {
        const thread = std.Thread.spawn(
            .{},
            struct {
                fn run(state: *MyState) !void {
                    std.Thread.yield() catch {};
                    clay.updateScrollContainers(false, .{}, 0);
                    state.redraw();
                }
            }.run,
            .{self},
        ) catch unreachable;
        thread.detach();
    }

    inline fn createLayout(self: *MyState) void {
        switch (self.view) {
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
