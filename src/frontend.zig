const builtin = @import("builtin");
const macos = @import("frontend/macos.zig");

pub const AppState = @import("frontend/common.zig").AppState;

pub const App = if (builtin.os.tag == .macos) macos.App else @compileError("unsupported platform");
