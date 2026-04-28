const std = @import("std");
const w = @import("win32");
const internal = @import("wio.internal.zig");
const types = @import("display_types.zig");

pub const DisplayIterator = struct {
    monitors: []w.HMONITOR,
    index: usize = 0,

    pub fn init() DisplayIterator {
        var list = std.ArrayListUnmanaged(w.HMONITOR).empty;
        _ = w.EnumDisplayMonitors(null, null, enumCallback, @as(w.LPARAM, @bitCast(@intFromPtr(&list))));
        return .{ .monitors = list.toOwnedSlice(internal.allocator) catch &.{} };
    }

    pub fn deinit(self: *DisplayIterator) void {
        internal.allocator.free(self.monitors);
    }

    pub fn next(self: *DisplayIterator) ?Display {
        if (self.index == self.monitors.len) return null;
        defer self.index += 1;
        return .{ .handle = self.monitors[self.index] };
    }
};

fn enumCallback(monitor: w.HMONITOR, _: w.HDC, _: [*c]w.RECT, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const list: *std.ArrayListUnmanaged(w.HMONITOR) = @ptrFromInt(@as(usize, @bitCast(lparam)));
    list.append(internal.allocator, monitor) catch {};
    return w.TRUE;
}

pub const Display = struct {
    handle: w.HMONITOR,

    pub fn release(_: Display) void {}

    pub fn getCurrentMode(self: Display) ?types.DisplayMode {
        const info_ex = getMonitorInfoEx(self.handle) orelse return null;
        const dev_mode = getDevMode(&info_ex) orelse return null;
        return .{
            .bounds = rectToBounds(info_ex.monitorInfo.rcMonitor),
            .usable_bounds = rectToBounds(info_ex.monitorInfo.rcWork),
            .content_scale = getContentScaleForMonitor(self.handle),
            .pixel_width = dev_mode.dmPelsWidth,
            .pixel_height = dev_mode.dmPelsHeight,
            .refresh_rate = queryRefreshRate(&info_ex) orelse .{ .hz = @floatFromInt(dev_mode.dmDisplayFrequency) },
        };
    }

    pub fn getBounds(self: Display) ?types.Bounds {
        var info: w.MONITORINFO = undefined;
        info.cbSize = @sizeOf(w.MONITORINFO);
        if (w.GetMonitorInfoW(self.handle, &info) == 0) return null;
        return rectToBounds(info.rcMonitor);
    }

    pub fn getUsableBounds(self: Display) ?types.Bounds {
        var info: w.MONITORINFO = undefined;
        info.cbSize = @sizeOf(w.MONITORINFO);
        if (w.GetMonitorInfoW(self.handle, &info) == 0) return null;
        return rectToBounds(info.rcWork);
    }

    pub fn getContentScale(self: Display) f64 {
        return getContentScaleForMonitor(self.handle);
    }

    pub fn getRefreshRate(self: Display) types.RefreshRate {
        const info_ex = getMonitorInfoEx(self.handle) orelse return .{};
        if (queryRefreshRate(&info_ex)) |rate| return rate;
        const dev_mode = getDevMode(&info_ex) orelse return .{};
        return .{ .hz = @floatFromInt(dev_mode.dmDisplayFrequency) };
    }
};

fn rectToBounds(rect: w.RECT) types.Bounds {
    return .{
        .x = rect.left,
        .y = rect.top,
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

fn getMonitorInfoEx(handle: w.HMONITOR) ?w.MONITORINFOEXW {
    var info: w.MONITORINFOEXW = undefined;
    info.monitorInfo.cbSize = @sizeOf(w.MONITORINFOEXW);
    if (w.GetMonitorInfoW(handle, &info.monitorInfo) == 0) return null;
    return info;
}

fn getDevMode(info_ex: *const w.MONITORINFOEXW) ?w.DEVMODEW {
    var mode: w.DEVMODEW = std.mem.zeroes(w.DEVMODEW);
    mode.dmSize = @intCast(@sizeOf(w.DEVMODEW));
    if (w.EnumDisplaySettingsW(&info_ex.szDevice, w.ENUM_CURRENT_SETTINGS, &mode) == 0) return null;
    return mode;
}

fn getContentScaleForMonitor(handle: w.HMONITOR) f64 {
    var dpi_x: u32 = 0;
    var dpi_y: u32 = 0;
    _ = w.GetDpiForMonitor(handle, w.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
    if (dpi_x == 0) return 1.0;
    return @as(f64, @floatFromInt(dpi_x)) / 96.0;
}

fn queryRefreshRate(info_ex: *const w.MONITORINFOEXW) ?types.RefreshRate {
    var num_paths: u32 = 0;
    var num_modes: u32 = 0;
    if (w.GetDisplayConfigBufferSizes(w.QDC_ONLY_ACTIVE_PATHS, &num_paths, &num_modes) != 0) return null;
    if (num_paths == 0) return null;

    const paths = internal.allocator.alloc(w.DISPLAYCONFIG_PATH_INFO, num_paths) catch return null;
    defer internal.allocator.free(paths);
    const modes = internal.allocator.alloc(w.DISPLAYCONFIG_MODE_INFO, num_modes) catch return null;
    defer internal.allocator.free(modes);

    if (w.QueryDisplayConfig(w.QDC_ONLY_ACTIVE_PATHS, &num_paths, paths.ptr, &num_modes, modes.ptr, null) != 0) return null;

    for (paths[0..num_paths]) |path| {
        var source_name: w.DISPLAYCONFIG_SOURCE_DEVICE_NAME = undefined;
        source_name.header.type = w.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source_name.header.size = @sizeOf(w.DISPLAYCONFIG_SOURCE_DEVICE_NAME);
        source_name.header.adapterId = path.sourceInfo.adapterId;
        source_name.header.id = path.sourceInfo.id;
        if (w.DisplayConfigGetDeviceInfo(&source_name.header) != 0) continue;

        const dev_len = std.mem.indexOfScalar(u16, &info_ex.szDevice, 0) orelse info_ex.szDevice.len;
        const src_len = std.mem.indexOfScalar(u16, &source_name.viewGdiDeviceName, 0) orelse source_name.viewGdiDeviceName.len;
        if (dev_len != src_len) continue;
        if (!std.mem.eql(u16, info_ex.szDevice[0..dev_len], source_name.viewGdiDeviceName[0..src_len])) continue;

        const num = path.targetInfo.refreshRate.Numerator;
        const den = path.targetInfo.refreshRate.Denominator;
        if (num == 0 or den == 0) continue;

        const num64: u64 = num;
        const den64: u64 = den;
        const divisor = gcd(num64, den64);
        return .{
            .hz = @as(f64, @floatFromInt(num64)) / @as(f64, @floatFromInt(den64)),
            .numerator = @intCast(num64 / divisor),
            .denominator = @intCast(den64 / divisor),
        };
    }
    return null;
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
