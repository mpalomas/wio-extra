const std = @import("std");

const display = @import("wiox_display");
const stub = display.stub;

test "refresh rate default represents unknown" {
    const rate = display.RefreshRate{};

    try std.testing.expectEqual(@as(f64, 0), rate.hz);
    try std.testing.expectEqual(@as(u32, 0), rate.numerator);
    try std.testing.expectEqual(@as(u32, 0), rate.denominator);
}

test "display mode carries geometry scale and refresh data" {
    const mode = display.DisplayMode{
        .bounds = .{ .x = -1920, .y = 0, .width = 1920, .height = 1080 },
        .usable_bounds = .{ .x = -1920, .y = 24, .width = 1920, .height = 1056 },
        .content_scale = 2.0,
        .pixel_width = 3840,
        .pixel_height = 2160,
        .refresh_rate = .{ .hz = 59.94, .numerator = 30000, .denominator = 1001 },
    };

    try std.testing.expectEqual(@as(i32, -1920), mode.bounds.x);
    try std.testing.expectEqual(@as(u32, 1920), mode.bounds.width);
    try std.testing.expectEqual(@as(i32, 24), mode.usable_bounds.y);
    try std.testing.expectEqual(@as(f64, 2.0), mode.content_scale);
    try std.testing.expectEqual(@as(u32, 3840), mode.pixel_width);
    try std.testing.expectEqual(@as(u32, 2160), mode.pixel_height);
    try std.testing.expectApproxEqAbs(@as(f64, 59.94), mode.refresh_rate.hz, 0.001);
    try std.testing.expectEqual(@as(u32, 30000), mode.refresh_rate.numerator);
    try std.testing.expectEqual(@as(u32, 1001), mode.refresh_rate.denominator);
}

test "stub backend satisfies display API contract" {
    var iterator = stub.DisplayIterator.init();
    defer iterator.deinit();

    try std.testing.expectEqual(@as(?stub.Display, null), iterator.next());

    const stub_display = stub.Display{};
    stub_display.release();
    try std.testing.expectEqual(@as(?display.DisplayMode, null), stub_display.getCurrentMode());
    try std.testing.expectEqual(@as(?display.Bounds, null), stub_display.getBounds());
    try std.testing.expectEqual(@as(?display.Bounds, null), stub_display.getUsableBounds());
    try std.testing.expectEqual(@as(f64, 0), stub_display.getContentScale());
    try std.testing.expectEqual(display.RefreshRate{}, stub_display.getRefreshRate());
}

test "display backend exposes required API shape" {
    comptime assertDisplayApi(display.DisplayIterator, display.Display);
    comptime assertDisplayApi(stub.DisplayIterator, stub.Display);
}

test "wayland display math compiles through sidecar module" {
    _ = display.wayland_math;
}

fn assertDisplayApi(comptime DisplayIterator: type, comptime Display: type) void {
    const iterator = @typeInfo(@TypeOf(DisplayIterator.init)).@"fn";
    if (iterator.return_type.? != DisplayIterator) @compileError("DisplayIterator.init must return DisplayIterator");

    const deinit_fn = @typeInfo(@TypeOf(DisplayIterator.deinit)).@"fn";
    if (deinit_fn.params.len != 1 or deinit_fn.params[0].type.? != *DisplayIterator or deinit_fn.return_type.? != void) {
        @compileError("DisplayIterator.deinit must be fn (*DisplayIterator) void");
    }

    const next = @typeInfo(@TypeOf(DisplayIterator.next)).@"fn";
    if (next.params.len != 1 or next.params[0].type.? != *DisplayIterator or next.return_type.? != ?Display) {
        @compileError("DisplayIterator.next must be fn (*DisplayIterator) ?Display");
    }

    const release = @typeInfo(@TypeOf(Display.release)).@"fn";
    if (release.params.len != 1 or release.params[0].type.? != Display or release.return_type.? != void) {
        @compileError("Display.release must be fn (Display) void");
    }

    const get_current_mode = @typeInfo(@TypeOf(Display.getCurrentMode)).@"fn";
    if (get_current_mode.params.len != 1 or get_current_mode.params[0].type.? != Display or get_current_mode.return_type.? != ?display.DisplayMode) {
        @compileError("Display.getCurrentMode must be fn (Display) ?DisplayMode");
    }

    const get_bounds = @typeInfo(@TypeOf(Display.getBounds)).@"fn";
    if (get_bounds.params.len != 1 or get_bounds.params[0].type.? != Display or get_bounds.return_type.? != ?display.Bounds) {
        @compileError("Display.getBounds must be fn (Display) ?Bounds");
    }

    const get_usable_bounds = @typeInfo(@TypeOf(Display.getUsableBounds)).@"fn";
    if (get_usable_bounds.params.len != 1 or get_usable_bounds.params[0].type.? != Display or get_usable_bounds.return_type.? != ?display.Bounds) {
        @compileError("Display.getUsableBounds must be fn (Display) ?Bounds");
    }

    const get_content_scale = @typeInfo(@TypeOf(Display.getContentScale)).@"fn";
    if (get_content_scale.params.len != 1 or get_content_scale.params[0].type.? != Display or get_content_scale.return_type.? != f64) {
        @compileError("Display.getContentScale must be fn (Display) f64");
    }

    const get_refresh_rate = @typeInfo(@TypeOf(Display.getRefreshRate)).@"fn";
    if (get_refresh_rate.params.len != 1 or get_refresh_rate.params[0].type.? != Display or get_refresh_rate.return_type.? != display.RefreshRate) {
        @compileError("Display.getRefreshRate must be fn (Display) RefreshRate");
    }
}
