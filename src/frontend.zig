const builtin = @import("builtin");
const macos = @import("frontend/macos.zig");

pub usingnamespace if (builtin.os.tag == .macos) @import("frontend/macos.zig") else @compileError("unsupported platform");
