const std = @import("std");
const types = @import("../display_types.zig");

pub const OutputState = struct {
    x: i32 = 0,
    y: i32 = 0,
    transform: i32 = 0,
    scale: i32 = 1,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    refresh_millihz: i32 = 0,
};

pub fn bounds(output: OutputState) types.Bounds {
    const scale = @max(output.scale, 1);
    const rotated = output.transform == 1 or output.transform == 3 or output.transform == 5 or output.transform == 7;
    const pixel_width = if (rotated) output.pixel_height else output.pixel_width;
    const pixel_height = if (rotated) output.pixel_width else output.pixel_height;
    return .{
        .x = output.x,
        .y = output.y,
        .width = divCeil(pixel_width, @intCast(scale)),
        .height = divCeil(pixel_height, @intCast(scale)),
    };
}

pub fn contentScale(output: OutputState) f64 {
    return @floatFromInt(@max(output.scale, 1));
}

pub fn refreshRate(output: OutputState) types.RefreshRate {
    if (output.refresh_millihz <= 0) return .{};
    const numerator: u64 = @intCast(output.refresh_millihz);
    const denominator: u64 = 1000;
    const divisor = gcd(numerator, denominator);
    return .{
        .hz = @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator)),
        .numerator = @intCast(numerator / divisor),
        .denominator = @intCast(denominator / divisor),
    };
}

fn divCeil(value: u32, divisor: u32) u32 {
    return (value + divisor - 1) / divisor;
}

fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const r = x % y;
        x = y;
        y = r;
    }
    return x;
}

test "wayland bounds convert current pixel mode to logical output area" {
    const actual = bounds(.{
        .x = -1920,
        .y = 120,
        .scale = 2,
        .pixel_width = 3840,
        .pixel_height = 2160,
    });

    try std.testing.expectEqual(types.Bounds{ .x = -1920, .y = 120, .width = 1920, .height = 1080 }, actual);
}

test "wayland bounds account for rotated output transforms" {
    const actual = bounds(.{
        .transform = 1,
        .scale = 1,
        .pixel_width = 1080,
        .pixel_height = 1920,
    });

    try std.testing.expectEqual(types.Bounds{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, actual);
}

test "wayland refresh rate converts millihertz to reduced ratio" {
    const actual = refreshRate(.{ .refresh_millihz = 59940 });

    try std.testing.expectApproxEqAbs(@as(f64, 59.94), actual.hz, 0.001);
    try std.testing.expectEqual(@as(u32, 2997), actual.numerator);
    try std.testing.expectEqual(@as(u32, 50), actual.denominator);
}
