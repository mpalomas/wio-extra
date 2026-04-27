const std = @import("std");
const internal = @import("wio.internal.zig");
const types = @import("display_types.zig");

extern fn wioGetDisplayCount() u32;
extern fn wioGetDisplayIds([*]c.CGDirectDisplayID, u32) u32;
extern fn wioGetDisplayBounds(c.CGDirectDisplayID, *i32, *i32, *u32, *u32) u8;
extern fn wioGetDisplayUsableBounds(c.CGDirectDisplayID, *i32, *i32, *u32, *u32) u8;
extern fn wioGetDisplayContentScale(c.CGDirectDisplayID) f64;

pub const DisplayIterator = struct {
    ids: []c.CGDirectDisplayID = &.{},
    index: usize = 0,

    pub fn init() DisplayIterator {
        const count = wioGetDisplayCount();
        if (count == 0) return .{};

        const ids = internal.allocator.alloc(c.CGDirectDisplayID, count) catch return .{};
        const len = wioGetDisplayIds(ids.ptr, count);
        return .{ .ids = ids[0..len] };
    }

    pub fn deinit(self: *DisplayIterator) void {
        internal.allocator.free(self.ids);
    }

    pub fn next(self: *DisplayIterator) ?Display {
        if (self.index == self.ids.len) return null;
        defer self.index += 1;
        return .{ .id = self.ids[self.index] };
    }
};

pub const Display = struct {
    id: c.CGDirectDisplayID,

    pub fn release(_: Display) void {}

    pub fn getCurrentMode(self: Display) ?types.DisplayMode {
        const bounds = self.getBounds() orelse return null;
        const usable_bounds = self.getUsableBounds() orelse return null;
        const mode = c.CGDisplayCopyDisplayMode(self.id) orelse return null;
        defer c.CGDisplayModeRelease(mode);

        return .{
            .bounds = bounds,
            .usable_bounds = usable_bounds,
            .content_scale = self.getContentScale(),
            .pixel_width = @intCast(c.CGDisplayModeGetPixelWidth(mode)),
            .pixel_height = @intCast(c.CGDisplayModeGetPixelHeight(mode)),
            .refresh_rate = self.getRefreshRate(),
        };
    }

    pub fn getBounds(self: Display) ?types.Bounds {
        return getBoundsWith(wioGetDisplayBounds, self.id);
    }

    pub fn getUsableBounds(self: Display) ?types.Bounds {
        return getBoundsWith(wioGetDisplayUsableBounds, self.id);
    }

    pub fn getContentScale(self: Display) f64 {
        return wioGetDisplayContentScale(self.id);
    }

    pub fn getRefreshRate(self: Display) types.RefreshRate {
        return exactRefreshRate(self.id) orelse fallbackRefreshRate(self.id);
    }
};

fn getBoundsWith(
    comptime func: *const fn (c.CGDirectDisplayID, *i32, *i32, *u32, *u32) u8,
    id: c.CGDirectDisplayID,
) ?types.Bounds {
    var x: i32 = undefined;
    var y: i32 = undefined;
    var width: u32 = undefined;
    var height: u32 = undefined;
    if (func(id, &x, &y, &width, &height) == 0) return null;
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn exactRefreshRate(id: c.CGDirectDisplayID) ?types.RefreshRate {
    var link: c.CVDisplayLinkRef = null;
    if (c.CVDisplayLinkCreateWithCGDisplay(id, &link) != c.kCVReturnSuccess) return null;
    const display_link = link orelse return null;
    defer c.CVDisplayLinkRelease(display_link);

    const period = c.CVDisplayLinkGetNominalOutputVideoRefreshPeriod(display_link);
    if (period.timeValue <= 0 or period.timeScale <= 0) return null;

    const numerator_u64: u64 = @intCast(period.timeScale);
    const denominator_u64: u64 = @intCast(period.timeValue);
    const divisor = gcd(numerator_u64, denominator_u64);
    const reduced_numerator = numerator_u64 / divisor;
    const reduced_denominator = denominator_u64 / divisor;

    var rate = types.RefreshRate{
        .hz = @as(f64, @floatFromInt(numerator_u64)) / @as(f64, @floatFromInt(denominator_u64)),
    };

    if (reduced_numerator <= std.math.maxInt(u32) and reduced_denominator <= std.math.maxInt(u32)) {
        rate.numerator = @intCast(reduced_numerator);
        rate.denominator = @intCast(reduced_denominator);
    }

    return rate;
}

fn fallbackRefreshRate(id: c.CGDirectDisplayID) types.RefreshRate {
    const mode = c.CGDisplayCopyDisplayMode(id) orelse return .{};
    defer c.CGDisplayModeRelease(mode);
    return .{ .hz = c.CGDisplayModeGetRefreshRate(mode) };
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

const c = struct {
    pub const SInt32 = c_int;
    pub const SInt64 = c_longlong;
    pub const Float64 = f64;
    pub const UInt32 = c_uint;
    pub const CVReturn = SInt32;
    pub const kCVReturnSuccess: CVReturn = 0;
    pub const struct_CVTime = extern struct {
        timeValue: SInt64,
        timeScale: SInt32,
        flags: UInt32,
    };
    pub const CVTime = struct_CVTime;
    pub const struct_OpaqueCVDisplayLink = opaque {};
    pub const CVDisplayLinkRef = ?*struct_OpaqueCVDisplayLink;
    pub const CGDirectDisplayID = UInt32;
    pub const struct_CGDisplayMode = opaque {};
    pub const CGDisplayModeRef = ?*struct_CGDisplayMode;

    pub extern fn CVDisplayLinkCreateWithCGDisplay(displayID: CGDirectDisplayID, displayLinkOut: [*c]CVDisplayLinkRef) CVReturn;
    pub extern fn CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink: CVDisplayLinkRef) CVTime;
    pub extern fn CVDisplayLinkRelease(displayLink: CVDisplayLinkRef) void;

    pub extern fn CGDisplayCopyDisplayMode(display: CGDirectDisplayID) CGDisplayModeRef;
    pub extern fn CGDisplayModeGetPixelWidth(mode: CGDisplayModeRef) usize;
    pub extern fn CGDisplayModeGetPixelHeight(mode: CGDisplayModeRef) usize;
    pub extern fn CGDisplayModeGetRefreshRate(mode: CGDisplayModeRef) Float64;
    pub extern fn CGDisplayModeRelease(mode: CGDisplayModeRef) void;
};
