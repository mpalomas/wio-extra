const builtin = @import("builtin");
const build_options = @import("build_options");

const backend = switch (builtin.os.tag) {
    else => if (build_options.display_force_stub) @import("display/stub.zig") else switch (builtin.os.tag) {
    .macos => @import("display/macos.zig"),
    .windows => @import("display/win32.zig"),
    .linux => if (!builtin.target.abi.isAndroid() and build_options.wayland) @import("display/wayland.zig") else @import("display/stub.zig"),
    else => @import("display/stub.zig"),
    },
};

const types = @import("display/types.zig");
pub const stub = @import("display/stub.zig");
pub const wayland_math = @import("display/wayland_math.zig");

pub const Bounds = types.Bounds;
pub const RefreshRate = types.RefreshRate;
pub const DisplayMode = types.DisplayMode;
pub const DisplayIterator = backend.DisplayIterator;
pub const Display = backend.Display;

pub fn deinit() void {
    if (@hasDecl(backend, "deinit")) backend.deinit();
}

pub fn getWindowDisplay(window: anytype) ?Display {
    if (@hasDecl(backend, "getWindowDisplay")) {
        return backend.getWindowDisplay(window);
    }
    return null;
}
