const std = @import("std");
const wio = @import("wio.zig");

fn enumCount(comptime T: type) usize {
    return std.meta.fields(T).len;
}

fn buttonIndex(button: GamepadButton) usize {
    return @intFromEnum(button);
}

fn axisIndex(axis: GamepadAxis) usize {
    return @intFromEnum(axis);
}

pub const GamepadButton = enum(u8) {
    south,
    east,
    west,
    north,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    misc1,
    right_paddle1,
    left_paddle1,
    right_paddle2,
    left_paddle2,
    touchpad,
    misc2,
    misc3,
    misc4,
    misc5,
    misc6,
};

pub const GamepadAxis = enum(u8) {
    leftx,
    lefty,
    rightx,
    righty,
    left_trigger,
    right_trigger,
};

pub const FaceStyle = enum {
    unknown,
    abxy,
    axby,
    bayx,
    sony,
};

pub const GamepadType = enum {
    unknown,
    standard,
    xbox360,
    xboxone,
    ps3,
    ps4,
    ps5,
    switchpro,
    joyconleft,
    joyconright,
    joyconpair,
    gamecube,
};

pub const HatMask = packed struct(u4) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
};

pub const GamepadState = struct {
    buttons: [enumCount(GamepadButton)]bool = [_]bool{false} ** enumCount(GamepadButton),
    axes: [enumCount(GamepadAxis)]f32 = [_]f32{0} ** enumCount(GamepadAxis),

    pub fn button(self: *const GamepadState, which: GamepadButton) bool {
        return self.buttons[buttonIndex(which)];
    }

    pub fn axis(self: *const GamepadState, which: GamepadAxis) f32 {
        return self.axes[axisIndex(which)];
    }
};

pub const ParseError = error{
    InvalidMapping,
    InvalidGuid,
    InvalidOutput,
    InvalidInput,
    InvalidHat,
};

pub const IdentifyError = error{
    MissingDeviceId,
};

pub const RuntimeError = error{
    NoMapping,
    OpenFailed,
};

pub const Input = union(enum) {
    button: usize,
    axis: struct {
        index: usize,
        min: i32,
        max: i32,
    },
    hat: struct {
        index: usize,
        mask: u4,
    },
};

pub const Output = union(enum) {
    button: GamepadButton,
    axis: struct {
        axis: GamepadAxis,
        min: i32,
        max: i32,
    },
};

pub const Binding = struct {
    input: Input,
    output: Output,
};

pub const Mapping = struct {
    guid: []u8,
    name: []u8,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    platform: ?[]u8 = null,
    mapping_type: GamepadType = .unknown,
    face: FaceStyle = .unknown,
    crc: ?u16 = null,

    pub fn deinit(self: *Mapping, allocator: std.mem.Allocator) void {
        allocator.free(self.guid);
        allocator.free(self.name);
        self.bindings.deinit(allocator);
        if (self.platform) |platform| allocator.free(platform);
        self.* = undefined;
    }

    pub fn matchesId(self: *const Mapping, id: []const u8) bool {
        return std.mem.eql(u8, self.guid, id);
    }

    pub fn mapState(self: *const Mapping, raw: anytype) GamepadState {
        var state = GamepadState{};
        for (self.bindings.items) |binding| {
            applyBinding(&state, binding, raw);
        }
        return state;
    }
};

pub const Database = struct {
    mappings: std.ArrayListUnmanaged(Mapping) = .empty,

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        for (self.mappings.items) |*mapping| {
            mapping.deinit(allocator);
        }
        self.mappings.deinit(allocator);
        self.* = undefined;
    }

    pub fn addMapping(self: *Database, allocator: std.mem.Allocator, text: []const u8) !void {
        var mapping = try parseMapping(allocator, text);
        errdefer mapping.deinit(allocator);

        for (self.mappings.items) |*existing| {
            if (std.mem.eql(u8, existing.guid, mapping.guid) and existing.crc == mapping.crc) {
                existing.deinit(allocator);
                existing.* = mapping;
                return;
            }
        }

        try self.mappings.append(allocator, mapping);
    }

    pub fn addMappingsFromText(self: *Database, allocator: std.mem.Allocator, text: []const u8) !usize {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.addMapping(allocator, line);
            count += 1;
        }
        return count;
    }

    pub fn findGuid(self: *const Database, guid: []const u8) ?*const Mapping {
        if (std.mem.eql(u8, guid, "xinput")) {
            for (self.mappings.items) |*mapping| {
                if (mapping.matchesId(guid)) return mapping;
            }
            return null;
        }

        const guid_bytes = parseGuidBytes(guid) orelse {
            for (self.mappings.items) |*mapping| {
                if (mapping.matchesId(guid)) return mapping;
            }
            return null;
        };

        if (self.findGuidBytes(guid_bytes, true, true)) |mapping| return mapping;
        if (self.findGuidBytes(guid_bytes, true, false)) |mapping| return mapping;

        if (guidUsesVersion(guid_bytes)) {
            if (self.findGuidBytes(guid_bytes, false, true)) |mapping| return mapping;
            if (self.findGuidBytes(guid_bytes, false, false)) |mapping| return mapping;
        }

        return null;
    }

    fn findGuidBytes(self: *const Database, guid: [16]u8, match_version: bool, exact_match_crc: bool) ?*const Mapping {
        var match_guid = guid;
        const crc = guidCrc(match_guid);
        clearGuidCrc(&match_guid);
        if (!match_version) clearGuidVersion(&match_guid);

        for (self.mappings.items) |*mapping| {
            var mapping_guid = parseGuidBytes(mapping.guid) orelse continue;
            clearGuidCrc(&mapping_guid);
            if (!match_version) clearGuidVersion(&mapping_guid);

            if (std.mem.eql(u8, &match_guid, &mapping_guid)) {
                if (mapping.crc) |mapping_crc| {
                    if (mapping_crc != crc) continue;
                    return mapping;
                }

                if (crc != 0 and exact_match_crc) continue;
                return mapping;
            }
        }
        return null;
    }
};

pub const DeviceIdentity = struct {
    runtime_id: []u8,
    name: []u8,
    info: ?wio.JoystickInfo,
    sdl_guid: []u8,

    pub fn deinit(self: *DeviceIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_id);
        allocator.free(self.name);
        allocator.free(self.sdl_guid);
        self.* = undefined;
    }
};

pub const GamepadDevice = struct {
    identity: DeviceIdentity,
    mapping: *const Mapping,
    joystick: wio.Joystick,

    /// The `Database` used here must outlive the returned handle because the
    /// selected mapping is borrowed, not copied.
    pub fn open(allocator: std.mem.Allocator, device: wio.JoystickDevice, db: *const Database) !GamepadDevice {
        var identity = try identifyDevice(allocator, device);
        errdefer identity.deinit(allocator);

        const mapping = db.findGuid(identity.sdl_guid) orelse return RuntimeError.NoMapping;
        const joystick = device.open() orelse return RuntimeError.OpenFailed;

        return .{
            .identity = identity,
            .mapping = mapping,
            .joystick = joystick,
        };
    }

    pub fn deinit(self: *GamepadDevice, allocator: std.mem.Allocator) void {
        self.joystick.close();
        self.identity.deinit(allocator);
        self.* = undefined;
    }

    pub fn poll(self: *GamepadDevice) ?GamepadState {
        const raw = self.joystick.poll() orelse return null;
        return self.mapping.mapState(raw);
    }
};

pub fn identifyDevice(allocator: std.mem.Allocator, device: wio.JoystickDevice) !DeviceIdentity {
    const runtime_id = device.getId(allocator) orelse return IdentifyError.MissingDeviceId;
    errdefer allocator.free(runtime_id);

    const raw_name = device.getName(allocator);
    defer if (raw_name.len != 0) allocator.free(raw_name);
    const name = try allocator.dupe(u8, raw_name);
    errdefer allocator.free(name);

    const info = device.getInfo();
    const sdl_guid = try createSdlGuidString(allocator, info, name);
    errdefer allocator.free(sdl_guid);

    return .{
        .runtime_id = runtime_id,
        .name = name,
        .info = info,
        .sdl_guid = sdl_guid,
    };
}

pub fn parseMapping(allocator: std.mem.Allocator, text: []const u8) !Mapping {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var pieces = std.mem.splitScalar(u8, trimmed, ',');

    const guid_raw = pieces.next() orelse return ParseError.InvalidMapping;
    const name_raw = pieces.next() orelse return ParseError.InvalidMapping;

    if (guid_raw.len == 0) return ParseError.InvalidGuid;
    if (!std.mem.eql(u8, guid_raw, "xinput") and guid_raw.len != 32) {
        return ParseError.InvalidGuid;
    }

    var mapping = Mapping{
        .guid = try allocator.dupe(u8, guid_raw),
        .name = try allocator.dupe(u8, name_raw),
    };
    errdefer mapping.deinit(allocator);

    while (pieces.next()) |piece_raw| {
        const piece = std.mem.trim(u8, piece_raw, " \t\r");
        if (piece.len == 0) continue;
        try parseEntry(allocator, &mapping, piece);
    }

    return mapping;
}

fn parseEntry(allocator: std.mem.Allocator, mapping: *Mapping, piece: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, piece, ':') orelse return;
    const key = piece[0..colon];
    const value = piece[colon + 1 ..];

    if (std.mem.eql(u8, key, "platform")) {
        if (mapping.platform) |old| allocator.free(old);
        mapping.platform = try allocator.dupe(u8, value);
        return;
    }
    if (std.mem.eql(u8, key, "type")) {
        mapping.mapping_type = parseType(value);
        return;
    }
    if (std.mem.eql(u8, key, "face")) {
        mapping.face = parseFace(value);
        return;
    }
    if (std.mem.eql(u8, key, "crc")) {
        mapping.crc = try std.fmt.parseUnsigned(u16, value, 16);
        return;
    }
    if (std.mem.eql(u8, key, "hint") or
        std.mem.eql(u8, key, "sdk>=") or
        std.mem.eql(u8, key, "sdk<="))
    {
        return;
    }

    try mapping.bindings.append(allocator, .{
        .input = try parseInput(value),
        .output = try parseOutput(key),
    });
}

const sdl_bus_unknown: u16 = 0x00;
const sdl_bus_usb: u16 = 0x03;

fn createSdlGuidString(allocator: std.mem.Allocator, info: ?wio.JoystickInfo, name: []const u8) ![]u8 {
    if (info) |raw| {
        if (raw.backend == .windows_xinput) {
            return allocator.dupe(u8, "xinput");
        }

        if (raw.vendor != null or raw.product != null or raw.version != null) {
            var guid = [_]u8{0} ** 16;
            const bus = raw.bus orelse switch (raw.backend) {
                .linux_evdev => sdl_bus_unknown,
                .windows_rawinput => sdl_bus_usb,
                .macos_iokit => sdl_bus_usb,
                else => sdl_bus_unknown,
            };
            writeLe16(guid[0..2], bus);
            writeLe16(guid[2..4], raw.guid_crc orelse sdlCrc16(0, name));
            writeLe16(guid[4..6], raw.vendor orelse 0);
            writeLe16(guid[8..10], raw.product orelse 0);
            writeLe16(guid[12..14], raw.version orelse 0);
            guid[14] = raw.driver_signature orelse 0;
            guid[15] = raw.driver_data orelse 0;

            return hexEncodeGuid(allocator, &guid);
        }
    }

    var guid = [_]u8{0} ** 16;
    writeLe16(guid[0..2], sdl_bus_unknown);
    writeLe16(guid[2..4], sdlCrc16(0, name));
    const copied = @min(name.len, guid.len - 4);
    @memcpy(guid[4 .. 4 + copied], name[0..copied]);
    return hexEncodeGuid(allocator, &guid);
}

fn writeLe16(out: []u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .little);
}

fn hexEncodeGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, guid.len * 2);
    const charset = "0123456789abcdef";
    for (guid, 0..) |byte, i| {
        out[i * 2] = charset[byte >> 4];
        out[i * 2 + 1] = charset[byte & 0x0F];
    }
    return out;
}

fn sdlCrc16(initial: u16, data: []const u8) u16 {
    var crc = initial;
    for (data) |byte| {
        crc = crc16ForByte(@as(u8, @truncate(crc)) ^ byte) ^ (crc >> 8);
    }
    return crc;
}

fn crc16ForByte(byte: u8) u16 {
    var r = byte;
    var crc: u16 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        crc = (if (((crc ^ r) & 1) != 0) @as(u16, 0xA001) else 0) ^ (crc >> 1);
        r >>= 1;
    }
    return crc;
}

fn parseGuidBytes(guid: []const u8) ?[16]u8 {
    if (guid.len != 32) return null;

    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        const hi = std.fmt.charToDigit(guid[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(guid[i * 2 + 1], 16) catch return null;
        byte.* = @as(u8, @intCast(hi << 4)) | @as(u8, @intCast(lo));
    }
    return bytes;
}

fn guidCrc(guid: [16]u8) u16 {
    return std.mem.readInt(u16, guid[2..4], .little);
}

fn clearGuidCrc(guid: *[16]u8) void {
    writeLe16(guid[2..4], 0);
}

fn guidVendor(guid: [16]u8) u16 {
    return std.mem.readInt(u16, guid[4..6], .little);
}

fn guidProduct(guid: [16]u8) u16 {
    return std.mem.readInt(u16, guid[8..10], .little);
}

fn clearGuidVersion(guid: *[16]u8) void {
    writeLe16(guid[12..14], 0);
}

fn guidUsesVersion(guid: [16]u8) bool {
    return guidVendor(guid) != 0 and guidProduct(guid) != 0;
}

test "parse mapping with metadata and bindings" {
    const allocator = std.testing.allocator;

    var mapping = try parseMapping(
        allocator,
        "030000007e0500000920000000000000,Nintendo Switch Pro Controller,type:switchpro,face:bayx,a:b0,b:b1,dpup:h0.1,leftx:a0,lefty:a1~,platform:Linux,crc:1234,",
    );
    defer mapping.deinit(allocator);

    try std.testing.expectEqualStrings("030000007e0500000920000000000000", mapping.guid);
    try std.testing.expectEqualStrings("Nintendo Switch Pro Controller", mapping.name);
    try std.testing.expectEqual(GamepadType.switchpro, mapping.mapping_type);
    try std.testing.expectEqual(FaceStyle.bayx, mapping.face);
    try std.testing.expectEqual(@as(?u16, 0x1234), mapping.crc);
    try std.testing.expectEqualStrings("Linux", mapping.platform.?);
    try std.testing.expectEqual(@as(usize, 5), mapping.bindings.items.len);
}

test "map state handles buttons hats half axes and inverted axes" {
    const allocator = std.testing.allocator;

    var mapping = try parseMapping(
        allocator,
        "xinput,Test Pad,a:b0,dpup:h0.1,leftx:a0,lefty:a1~,lefttrigger:+a2,righttrigger:-a2,",
    );
    defer mapping.deinit(allocator);

    const raw = wio.JoystickState{
        .axes = &[_]u16{
            0xFFFF,
            0x0000,
            0xC000,
        },
        .hats = &[_]wio.Hat{
            .{ .up = true },
        },
        .buttons = &[_]bool{true},
    };

    const state = mapping.mapState(raw);

    try std.testing.expect(state.button(.south));
    try std.testing.expect(state.button(.dpad_up));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.axis(.leftx), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.axis(.lefty), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50001526), state.axis(.left_trigger), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.axis(.right_trigger), 0.001);
}

test "sdl guid synthesis for xinput and usb device" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(u16, 0xbb3d), sdlCrc16(0, "123456789"));

    const xinput_guid = try createSdlGuidString(allocator, .{
        .backend = .windows_xinput,
        .bus = 0x03,
    }, "Xbox Controller");
    defer allocator.free(xinput_guid);
    try std.testing.expectEqualStrings("xinput", xinput_guid);

    const switch_guid = try createSdlGuidString(allocator, .{
        .backend = .macos_iokit,
        .bus = 0x03,
        .vendor = 0x057e,
        .product = 0x2009,
        .version = 0x0000,
    }, "Nintendo Switch Pro Controller");
    defer allocator.free(switch_guid);
    try std.testing.expectEqualStrings("030056fb7e0500000920000000000000", switch_guid);

    const rawinput_guid = try createSdlGuidString(allocator, .{
        .backend = .windows_rawinput,
        .bus = 0x03,
        .vendor = 0x045e,
        .product = 0x02e0,
        .version = 0x0903,
        .guid_crc = 0,
        .driver_signature = 'r',
    }, "Xbox Wireless Controller");
    defer allocator.free(rawinput_guid);
    try std.testing.expectEqualStrings("030000005e040000e002000003097200", rawinput_guid);
}

test "database lookup with real sdl db subset" {
    const allocator = std.testing.allocator;

    const subset =
        \\xinput,*,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,
        \\03000000491900001904000000000000,Amazon Luna Controller,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,misc1:b9,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b7,x:b2,y:b3,
        \\030000007e0500000920000000000000,Nintendo Switch Pro Controller,a:b0,b:b1,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:b6,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:b7,rightx:a2,righty:a3,start:b9,x:b2,y:b3,hint:!SDL_GAMECONTROLLER_USE_BUTTON_LABELS:=1,
    ;

    var db = Database{};
    defer db.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), try db.addMappingsFromText(allocator, subset));

    try std.testing.expect(db.findGuid("xinput") != null);

    const luna_guid = try createSdlGuidString(allocator, .{
        .backend = .linux_evdev,
        .bus = 0x03,
        .vendor = 0x1949,
        .product = 0x0419,
        .version = 0x0000,
    }, "Amazon Luna Controller");
    defer allocator.free(luna_guid);
    try std.testing.expectEqualStrings("030055c0491900001904000000000000", luna_guid);
    const luna_mapping = db.findGuid(luna_guid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Amazon Luna Controller", luna_mapping.name);

    const switch_guid = try createSdlGuidString(allocator, .{
        .backend = .linux_evdev,
        .bus = 0x03,
        .vendor = 0x057e,
        .product = 0x2009,
        .version = 0x0000,
    }, "Nintendo Switch Pro Controller");
    defer allocator.free(switch_guid);
    try std.testing.expect(db.findGuid(switch_guid) != null);
}

test "database lookup follows sdl crc and version fallback rules" {
    const allocator = std.testing.allocator;

    const subset =
        \\03000000c82d00000160000000000000,8BitDo SN30 Pro v2,crc:769e,a:b1,b:b0,
        \\03000000c82d00000160000000000000,8BitDo SN30 Pro v1,crc:fa59,a:b1,b:b0,
        \\030000005e040000e002000000000000,Xbox Wireless Controller,a:b0,b:b1,
    ;

    var db = Database{};
    defer db.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), try db.addMappingsFromText(allocator, subset));
    try std.testing.expectEqual(@as(usize, 3), db.mappings.items.len);

    const sn30_crc_guid = "03009e76c82d00000160000000000000";
    const sn30_mapping = db.findGuid(sn30_crc_guid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("8BitDo SN30 Pro v2", sn30_mapping.name);
    try std.testing.expect(db.findGuid("03000000c82d00000160000000000000") == null);

    const xbox_newer_version_guid = "030000005e040000e0020000ffff0000";
    const xbox_mapping = db.findGuid(xbox_newer_version_guid) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Xbox Wireless Controller", xbox_mapping.name);
}

test "sdl db compatibility sweep for common controller families" {
    const allocator = std.testing.allocator;

    const subset =
        \\03000000c82d00000660000000000000,8BitDo Pro 2,a:b1,b:b0,back:b10,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b6,leftstick:b13,lefttrigger:b8,leftx:a0,lefty:a1,rightshoulder:b7,rightstick:b14,righttrigger:b9,rightx:a3,righty:a4,start:b11,x:b4,y:b3,
        \\05000000c82d00000660000000010000,8BitDo Pro 2 Bluetooth,a:b1,b:b0,back:b10,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b6,leftstick:b13,lefttrigger:a5,leftx:a0,lefty:a1,rightshoulder:b7,rightstick:b14,righttrigger:a4,rightx:a2,righty:a3,start:b11,x:b4,y:b3,
        \\030000004c050000e60c000000010000,PS5 Controller USB,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,
        \\050000004c050000e60c000000010000,PS5 Controller Bluetooth,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,
        \\030000005e040000d102000000000000,Xbox One Wired Controller,a:b0,b:b1,back:b9,dpdown:b12,dpleft:b13,dpright:b14,dpup:b11,guide:b10,leftshoulder:b4,leftstick:b6,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b7,righttrigger:a5,rightx:a3,righty:a4,start:b8,x:b2,y:b3,
        \\050000005e040000e002000003090000,Xbox One Wireless Controller Bluetooth,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,
    ;

    var db = Database{};
    defer db.deinit(allocator);
    _ = try db.addMappingsFromText(allocator, subset);

    const cases = [_]struct {
        info: wio.JoystickInfo,
        name: []const u8,
        expected: []const u8,
    }{
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x03, .vendor = 0x2dc8, .product = 0x6006, .version = 0x0000 },
            .name = "8BitDo Pro 2",
            .expected = "8BitDo Pro 2",
        },
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x05, .vendor = 0x2dc8, .product = 0x6006, .version = 0x0100 },
            .name = "8BitDo Pro 2",
            .expected = "8BitDo Pro 2 Bluetooth",
        },
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x03, .vendor = 0x054c, .product = 0x0ce6, .version = 0x0100 },
            .name = "PS5 Controller",
            .expected = "PS5 Controller USB",
        },
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x05, .vendor = 0x054c, .product = 0x0ce6, .version = 0x0100 },
            .name = "PS5 Controller",
            .expected = "PS5 Controller Bluetooth",
        },
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x03, .vendor = 0x045e, .product = 0x02d1, .version = 0x0000 },
            .name = "Xbox One Wired Controller",
            .expected = "Xbox One Wired Controller",
        },
        .{
            .info = .{ .backend = .linux_evdev, .bus = 0x05, .vendor = 0x045e, .product = 0x02e0, .version = 0x0903 },
            .name = "Xbox One Wireless Controller",
            .expected = "Xbox One Wireless Controller Bluetooth",
        },
    };

    for (cases) |case| {
        const guid = try createSdlGuidString(allocator, case.info, case.name);
        defer allocator.free(guid);
        const mapping = db.findGuid(guid) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(case.expected, mapping.name);
    }
}

fn parseType(value: []const u8) GamepadType {
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "xbox360")) return .xbox360;
    if (std.mem.eql(u8, value, "xboxone")) return .xboxone;
    if (std.mem.eql(u8, value, "ps3")) return .ps3;
    if (std.mem.eql(u8, value, "ps4")) return .ps4;
    if (std.mem.eql(u8, value, "ps5")) return .ps5;
    if (std.mem.eql(u8, value, "switchpro")) return .switchpro;
    if (std.mem.eql(u8, value, "joyconleft")) return .joyconleft;
    if (std.mem.eql(u8, value, "joyconright")) return .joyconright;
    if (std.mem.eql(u8, value, "joyconpair")) return .joyconpair;
    if (std.mem.eql(u8, value, "gamecube")) return .gamecube;
    return .unknown;
}

fn parseFace(value: []const u8) FaceStyle {
    if (std.mem.eql(u8, value, "abxy")) return .abxy;
    if (std.mem.eql(u8, value, "axby")) return .axby;
    if (std.mem.eql(u8, value, "bayx")) return .bayx;
    if (std.mem.eql(u8, value, "sony")) return .sony;
    return .unknown;
}

fn parseOutput(token: []const u8) !Output {
    var name = token;
    var half_axis: u8 = 0;

    if (name.len != 0 and (name[0] == '+' or name[0] == '-')) {
        half_axis = name[0];
        name = name[1..];
    }

    if (parseAxisName(name)) |axis| {
        return .{ .axis = .{
            .axis = axis,
            .min = switch (axis) {
                .left_trigger, .right_trigger => 0,
                else => if (half_axis == '-') 0 else -32768,
            },
            .max = switch (axis) {
                .left_trigger, .right_trigger => 32767,
                else => if (half_axis == '+') 32767 else if (half_axis == '-') -32768 else 32767,
            },
        } };
    }

    return .{ .button = parseButtonName(name) orelse return ParseError.InvalidOutput };
}

fn parseAxisName(name: []const u8) ?GamepadAxis {
    if (std.mem.eql(u8, name, "leftx")) return .leftx;
    if (std.mem.eql(u8, name, "lefty")) return .lefty;
    if (std.mem.eql(u8, name, "rightx")) return .rightx;
    if (std.mem.eql(u8, name, "righty")) return .righty;
    if (std.mem.eql(u8, name, "lefttrigger")) return .left_trigger;
    if (std.mem.eql(u8, name, "righttrigger")) return .right_trigger;
    return null;
}

fn parseButtonName(name: []const u8) ?GamepadButton {
    if (std.mem.eql(u8, name, "a")) return .south;
    if (std.mem.eql(u8, name, "b")) return .east;
    if (std.mem.eql(u8, name, "x")) return .west;
    if (std.mem.eql(u8, name, "y")) return .north;
    if (std.mem.eql(u8, name, "back")) return .back;
    if (std.mem.eql(u8, name, "guide")) return .guide;
    if (std.mem.eql(u8, name, "start")) return .start;
    if (std.mem.eql(u8, name, "leftstick")) return .left_stick;
    if (std.mem.eql(u8, name, "rightstick")) return .right_stick;
    if (std.mem.eql(u8, name, "leftshoulder")) return .left_shoulder;
    if (std.mem.eql(u8, name, "rightshoulder")) return .right_shoulder;
    if (std.mem.eql(u8, name, "dpup")) return .dpad_up;
    if (std.mem.eql(u8, name, "dpdown")) return .dpad_down;
    if (std.mem.eql(u8, name, "dpleft")) return .dpad_left;
    if (std.mem.eql(u8, name, "dpright")) return .dpad_right;
    if (std.mem.eql(u8, name, "misc1")) return .misc1;
    if (std.mem.eql(u8, name, "paddle1")) return .right_paddle1;
    if (std.mem.eql(u8, name, "paddle2")) return .left_paddle1;
    if (std.mem.eql(u8, name, "paddle3")) return .right_paddle2;
    if (std.mem.eql(u8, name, "paddle4")) return .left_paddle2;
    if (std.mem.eql(u8, name, "touchpad")) return .touchpad;
    if (std.mem.eql(u8, name, "misc2")) return .misc2;
    if (std.mem.eql(u8, name, "misc3")) return .misc3;
    if (std.mem.eql(u8, name, "misc4")) return .misc4;
    if (std.mem.eql(u8, name, "misc5")) return .misc5;
    if (std.mem.eql(u8, name, "misc6")) return .misc6;
    return null;
}

fn parseInput(token: []const u8) !Input {
    if (token.len < 2) return ParseError.InvalidInput;

    var text = token;
    var half_axis: u8 = 0;
    var invert = false;

    if (text[0] == '+' or text[0] == '-') {
        half_axis = text[0];
        text = text[1..];
    }
    if (text.len != 0 and text[text.len - 1] == '~') {
        invert = true;
        text = text[0 .. text.len - 1];
    }

    switch (text[0]) {
        'b' => return .{
            .button = try std.fmt.parseUnsigned(usize, text[1..], 10),
        },
        'a' => {
            var min: i32 = -32768;
            var max: i32 = 32767;
            if (half_axis == '+') {
                min = 0;
                max = 32767;
            } else if (half_axis == '-') {
                min = 0;
                max = -32768;
            }
            if (invert) {
                const tmp = min;
                min = max;
                max = tmp;
            }
            return .{ .axis = .{
                .index = try std.fmt.parseUnsigned(usize, text[1..], 10),
                .min = min,
                .max = max,
            } };
        },
        'h' => {
            const dot = std.mem.indexOfScalar(u8, text, '.') orelse return ParseError.InvalidHat;
            const hat_index = try std.fmt.parseUnsigned(usize, text[1..dot], 10);
            const hat_mask = try std.fmt.parseUnsigned(u4, text[dot + 1 ..], 10);
            return .{ .hat = .{
                .index = hat_index,
                .mask = hat_mask,
            } };
        },
        else => return ParseError.InvalidInput,
    }
}

fn applyBinding(state: *GamepadState, binding: Binding, raw: anytype) void {
    switch (binding.output) {
        .button => |button| {
            const active = evaluateButtonInput(binding.input, raw);
            state.buttons[buttonIndex(button)] = state.buttons[buttonIndex(button)] or active;
        },
        .axis => |axis_out| {
            const value = evaluateAxisInput(binding.input, raw, axis_out.min, axis_out.max);
            const index = axisIndex(axis_out.axis);
            if (@abs(value) > @abs(state.axes[index])) {
                state.axes[index] = value;
            }
        },
    }
}

fn evaluateButtonInput(input: Input, raw: anytype) bool {
    return switch (input) {
        .button => |index| index < raw.buttons.len and raw.buttons[index],
        .hat => |hat| hat.index < raw.hats.len and hatMatches(raw.hats[hat.index], hat.mask),
        .axis => |axis| @abs(projectAxisRange(getAxisSigned(raw, axis.index), axis.min, axis.max)) > 0.5,
    };
}

fn evaluateAxisInput(input: Input, raw: anytype, output_min: i32, output_max: i32) f32 {
    return switch (input) {
        .button => |index| if (index < raw.buttons.len and raw.buttons[index]) axisRangeToFloat(output_min, output_max, 1.0) else 0,
        .hat => |hat| if (hat.index < raw.hats.len and hatMatches(raw.hats[hat.index], hat.mask)) axisRangeToFloat(output_min, output_max, 1.0) else 0,
        .axis => |axis| axisRangeToFloat(output_min, output_max, axisFactor(getAxisSigned(raw, axis.index), axis.min, axis.max)),
    };
}

fn getAxisSigned(raw: anytype, index: usize) i32 {
    if (index >= raw.axes.len) return 0;
    return @as(i32, raw.axes[index]) - 32768;
}

fn axisFactor(value: i32, min: i32, max: i32) f32 {
    return projectAxisRange(value, min, max);
}

fn projectAxisRange(value: i32, min: i32, max: i32) f32 {
    if (min == max) return 0;

    if (min < max) {
        const clamped = std.math.clamp(value, min, max);
        const num: f32 = @floatFromInt(clamped - min);
        const den: f32 = @floatFromInt(max - min);
        return num / den;
    }

    const clamped = std.math.clamp(value, max, min);
    const num: f32 = @floatFromInt(min - clamped);
    const den: f32 = @floatFromInt(min - max);
    return num / den;
}

fn axisRangeToFloat(output_min: i32, output_max: i32, factor: f32) f32 {
    if (output_min == 0 and output_max == 32767) {
        return factor;
    }
    if (output_min == 0 and output_max == -32768) {
        return -factor;
    }
    const minf: f32 = @floatFromInt(output_min);
    const maxf: f32 = @floatFromInt(output_max);
    const signed = minf + (maxf - minf) * factor;
    return std.math.clamp(signed / 32767.0, -1.0, 1.0);
}

fn hatMatches(hat: anytype, mask: u4) bool {
    const actual: u4 = @bitCast(HatMask{
        .up = hat.up,
        .right = hat.right,
        .down = hat.down,
        .left = hat.left,
    });
    return (actual & mask) == mask;
}
