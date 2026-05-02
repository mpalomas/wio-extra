const std = @import("std");
const wio = @import("wio");
const h = @import("c");
const internal = wio.internal;
const types = @import("types.zig");
const math = @import("wayland_math.zig");
const wayland = wio.backend.wayland;

const Output = struct {
    name: u32,
    output: ?*h.wl_output,
    xdg_output: ?*h.zxdg_output_v1 = null,
    connected: bool = true,
    state: math.OutputState = .{},
    has_logical_position: bool = false,
};

var initialized = false;
var registry: ?*h.wl_registry = null;
var xdg_output_manager: ?*h.zxdg_output_manager_v1 = null;
var outputs: std.ArrayListUnmanaged(*Output) = .empty;

pub fn deinit() void {
    for (outputs.items) |output| {
        if (output.xdg_output) |xdg_output| h.zxdg_output_v1_destroy(xdg_output);
        if (output.output) |wl_output| h.wl_output_destroy(wl_output);
        internal.allocator.destroy(output);
    }
    outputs.deinit(internal.allocator);
    outputs = .empty;
    if (xdg_output_manager) |manager| h.zxdg_output_manager_v1_destroy(manager);
    xdg_output_manager = null;
    if (registry) |wl_registry| h.wl_registry_destroy(wl_registry);
    registry = null;
    initialized = false;
}

pub const DisplayIterator = struct {
    snapshot: []*Output = &.{},
    index: usize = 0,

    pub fn init() DisplayIterator {
        ensureInit();

        var list = std.ArrayListUnmanaged(*Output).empty;
        for (outputs.items) |output| {
            if (output.connected) list.append(internal.allocator, output) catch {};
        }
        return .{ .snapshot = list.toOwnedSlice(internal.allocator) catch &.{} };
    }

    pub fn deinit(self: *DisplayIterator) void {
        internal.allocator.free(self.snapshot);
    }

    pub fn next(self: *DisplayIterator) ?Display {
        if (self.index == self.snapshot.len) return null;
        defer self.index += 1;
        return .{ .output = self.snapshot[self.index] };
    }
};

pub const Display = struct {
    output: *Output,

    pub fn release(_: Display) void {}

    pub fn getCurrentMode(self: Display) ?types.DisplayMode {
        const output = self.liveOutput() orelse return null;
        const bounds = outputBounds(output);
        return .{
            .bounds = bounds,
            .usable_bounds = bounds,
            .content_scale = math.contentScale(output.state),
            .pixel_width = math.pixelSize(output.state).width,
            .pixel_height = math.pixelSize(output.state).height,
            .refresh_rate = math.refreshRate(output.state),
        };
    }

    pub fn getBounds(self: Display) ?types.Bounds {
        return outputBounds(self.liveOutput() orelse return null);
    }

    pub fn getUsableBounds(self: Display) ?types.Bounds {
        return self.getBounds();
    }

    pub fn getContentScale(self: Display) f64 {
        const output = self.liveOutput() orelse return 0;
        return math.contentScale(output.state);
    }

    pub fn getRefreshRate(self: Display) types.RefreshRate {
        const output = self.liveOutput() orelse return .{};
        return math.refreshRate(output.state);
    }

    fn liveOutput(self: Display) ?*const Output {
        if (!self.output.connected or self.output.output == null) return null;
        if (self.output.state.pixel_width == 0 or self.output.state.pixel_height == 0) return null;
        return self.output;
    }
};

fn ensureInit() void {
    if (initialized) return;
    registry = h.wl_display_get_registry(wayland.display) orelse return;
    _ = h.wl_registry_add_listener(registry, &registry_listener, null);
    _ = h.wl_display_roundtrip(wayland.display);
    _ = h.wl_display_roundtrip(wayland.display);
    initialized = true;
}

fn outputBounds(output: *const Output) types.Bounds {
    return math.bounds(output.state);
}

fn bindOutput(registry_ptr: ?*h.wl_registry, name: u32, version: u32) void {
    const wl_output: *h.wl_output = @ptrCast(h.wl_registry_bind(registry_ptr, name, &h.wl_output_interface, @min(version, 4)) orelse return);
    const output = internal.allocator.create(Output) catch {
        h.wl_output_destroy(wl_output);
        return;
    };
    output.* = .{
        .name = name,
        .output = wl_output,
    };
    outputs.append(internal.allocator, output) catch {
        h.wl_output_destroy(wl_output);
        internal.allocator.destroy(output);
        return;
    };
    _ = h.wl_output_add_listener(wl_output, &output_listener, output);
    bindXdgOutput(output);
}

fn bindXdgOutputManager(registry_ptr: ?*h.wl_registry, name: u32, version: u32) void {
    xdg_output_manager = @ptrCast(h.wl_registry_bind(registry_ptr, name, &h.zxdg_output_manager_v1_interface, @min(version, 3)) orelse return);
    for (outputs.items) |output| bindXdgOutput(output);
}

fn bindXdgOutput(output: *Output) void {
    if (output.xdg_output != null) return;
    const manager = xdg_output_manager orelse return;
    const wl_output = output.output orelse return;
    output.xdg_output = h.zxdg_output_manager_v1_get_xdg_output(manager, wl_output) orelse return;
    _ = h.zxdg_output_v1_add_listener(output.xdg_output, &xdg_output_listener, output);
}

const registry_listener = h.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(_: ?*anyopaque, registry_ptr: ?*h.wl_registry, name: u32, interface_ptr: [*c]const u8, version: u32) callconv(.c) void {
    const interface = std.mem.sliceTo(interface_ptr, 0);
    if (std.mem.eql(u8, interface, "wl_output")) {
        bindOutput(registry_ptr, name, version);
    } else if (std.mem.eql(u8, interface, "zxdg_output_manager_v1")) {
        bindXdgOutputManager(registry_ptr, name, version);
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*h.wl_registry, name: u32) callconv(.c) void {
    for (outputs.items) |output| {
        if (output.name != name or !output.connected) continue;
        output.connected = false;
        if (output.xdg_output) |xdg_output| {
            h.zxdg_output_v1_destroy(xdg_output);
            output.xdg_output = null;
        }
        if (output.output) |wl_output| {
            h.wl_output_destroy(wl_output);
            output.output = null;
        }
        return;
    }
}

const output_listener = h.wl_output_listener{
    .geometry = outputGeometry,
    .mode = outputMode,
    .done = outputDone,
    .scale = outputScale,
    .name = outputName,
    .description = outputDescription,
};

fn outputGeometry(
    data: ?*anyopaque,
    _: ?*h.wl_output,
    x: c_int,
    y: c_int,
    _: c_int,
    _: c_int,
    _: c_int,
    _: [*c]const u8,
    _: [*c]const u8,
    transform: c_int,
) callconv(.c) void {
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    if (!output.has_logical_position) {
        output.state.x = x;
        output.state.y = y;
    }
    output.state.transform = transform;
}

fn outputMode(data: ?*anyopaque, _: ?*h.wl_output, flags: u32, width: c_int, height: c_int, refresh: c_int) callconv(.c) void {
    if (flags & h.WL_OUTPUT_MODE_CURRENT == 0) return;
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    output.state.pixel_width = std.math.cast(u32, width) orelse 0;
    output.state.pixel_height = std.math.cast(u32, height) orelse 0;
    output.state.refresh_millihz = refresh;
}

fn outputDone(_: ?*anyopaque, _: ?*h.wl_output) callconv(.c) void {}

fn outputScale(data: ?*anyopaque, _: ?*h.wl_output, factor: c_int) callconv(.c) void {
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    output.state.scale = @max(factor, 1);
}

fn outputName(_: ?*anyopaque, _: ?*h.wl_output, _: [*c]const u8) callconv(.c) void {}

fn outputDescription(_: ?*anyopaque, _: ?*h.wl_output, _: [*c]const u8) callconv(.c) void {}

const xdg_output_listener = h.zxdg_output_v1_listener{
    .logical_position = xdgOutputLogicalPosition,
    .logical_size = xdgOutputLogicalSize,
    .done = xdgOutputDone,
    .name = xdgOutputName,
    .description = xdgOutputDescription,
};

fn xdgOutputLogicalPosition(data: ?*anyopaque, _: ?*h.zxdg_output_v1, x: i32, y: i32) callconv(.c) void {
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    output.state.x = x;
    output.state.y = y;
    output.has_logical_position = true;
}

fn xdgOutputLogicalSize(data: ?*anyopaque, _: ?*h.zxdg_output_v1, width: i32, height: i32) callconv(.c) void {
    const output: *Output = @ptrCast(@alignCast(data orelse return));
    output.state.logical_width = std.math.cast(u32, width) orelse 0;
    output.state.logical_height = std.math.cast(u32, height) orelse 0;
    output.state.has_logical_size = output.state.logical_width > 0 and output.state.logical_height > 0;
}

fn xdgOutputDone(_: ?*anyopaque, _: ?*h.zxdg_output_v1) callconv(.c) void {}

fn xdgOutputName(_: ?*anyopaque, _: ?*h.zxdg_output_v1, _: [*c]const u8) callconv(.c) void {}

fn xdgOutputDescription(_: ?*anyopaque, _: ?*h.zxdg_output_v1, _: [*c]const u8) callconv(.c) void {}
