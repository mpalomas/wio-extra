pub const Bounds = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RefreshRate = struct {
    hz: f64 = 0,
    numerator: u32 = 0,
    denominator: u32 = 0,
};

pub const DisplayMode = struct {
    bounds: Bounds,
    usable_bounds: Bounds,
    content_scale: f64,
    pixel_width: u32,
    pixel_height: u32,
    refresh_rate: RefreshRate,
};
