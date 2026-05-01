const builtin = @import("builtin");
const build_options = @import("build_options");

const backend = switch (builtin.os.tag) {
    .macos => @import("macos_display.zig"),
    .windows => @import("win32_display.zig"),
    .linux => if (!builtin.target.abi.isAndroid() and build_options.wayland) @import("unix/wayland_display.zig") else @import("display_stub.zig"),
    else => @import("display_stub.zig"),
};

const types = @import("display_types.zig");

pub const Bounds = types.Bounds;
pub const RefreshRate = types.RefreshRate;
pub const DisplayMode = types.DisplayMode;
pub const DisplayIterator = backend.DisplayIterator;
pub const Display = backend.Display;
