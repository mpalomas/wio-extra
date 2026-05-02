const types = @import("types.zig");

pub fn deinit() void {}

pub const DisplayIterator = struct {
    pub fn init() DisplayIterator {
        return .{};
    }

    pub fn deinit(_: *DisplayIterator) void {}

    pub fn next(_: *DisplayIterator) ?Display {
        return null;
    }
};

pub const Display = struct {
    pub fn release(_: Display) void {}

    pub fn getCurrentMode(_: Display) ?types.DisplayMode {
        return null;
    }

    pub fn getBounds(_: Display) ?types.Bounds {
        return null;
    }

    pub fn getUsableBounds(_: Display) ?types.Bounds {
        return null;
    }

    pub fn getContentScale(_: Display) f64 {
        return 0;
    }

    pub fn getRefreshRate(_: Display) types.RefreshRate {
        return .{};
    }
};
