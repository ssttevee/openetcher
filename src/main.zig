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

    var disks_mutex: std.Thread.Mutex = .{};
    var disks: ?[]const platform.DeviceDescriptor = null;

    const CompressionType = enum { none, gzip, xz, zstd };

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
                                clay.text(std.fmt.allocPrint(self.arena.allocator(), "{d:3.2}", .{HumanizeBytes.init(selected_image.real_size)}) catch unreachable, &btn_text_config);
                            } else {
                                clay.text(std.fmt.allocPrint(self.arena.allocator(), "calculating size ({d:3.2})", .{HumanizeBytes.init(selected_image.real_size)}) catch unreachable, &btn_text_config);
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
                        if (self.selected_image != null and self.selected_disks.count() != 0) colors.highlighted_btn else colors.btn,
                        if (self.selected_image != null and self.selected_disks.count() != 0 and self.current_hover_state.flash) &highlighted_btn_text_config else &btn_text_config,
                        struct {
                            fn onHover(element_id: clay.ElementId, pointer_data: clay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                _ = element_id;

                                const state: *FrontPage = @alignCast(@ptrCast(user_data));
                                if (state.selected_image == null or state.selected_disks.count() == 0) return;

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
            .size = std.math.maxInt(u64),
            .block_size = 1,
            .logical_block_size = 1,
            .is_virtual = true,
        };

        @memcpy(devices_with_devnull[1..], devices);

        disks_mutex.lock();
        defer disks_mutex.unlock();

        disks = devices_with_devnull;

        self.parentState().redraw();
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

const Flashing = struct {
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

    fn deinit(self: *const Flashing) void {
        self.arena.deinit();
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
