const builtin = @import("builtin");

pub usingnamespace @import("platform/common.zig");

pub usingnamespace if (builtin.os.tag == .macos) @import("platform/macos.zig") else @compileError("unsupported platform");
