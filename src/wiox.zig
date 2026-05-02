pub const display = @import("wiox/display.zig");
pub const gamepad = @import("wiox/gamepad.zig");

pub fn deinit() void {
    display.deinit();
}
