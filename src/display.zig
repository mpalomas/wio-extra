const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("macos_display.zig"),
    .windows => @import("win32_display.zig"),
    else => @import("display_stub.zig"),
};

const types = @import("display_types.zig");

pub const Bounds = types.Bounds;
pub const RefreshRate = types.RefreshRate;
pub const DisplayMode = types.DisplayMode;
pub const DisplayIterator = backend.DisplayIterator;
pub const Display = backend.Display;
