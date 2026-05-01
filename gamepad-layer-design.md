# Minimal-Change Gamepad Layer Design for `wio`

## Goal

Add SDL-style gamepad support to this fork while minimizing divergence from the
upstream `wio` repo.

This means:

- preserve `wio` as a raw platform/input layer
- avoid large edits to existing backend files
- keep SDL mapping logic outside core `wio`
- make it possible to consume SDL mapping strings and SDL-style controller DBs

## Non-goals

This design does not try to:

- turn `wio` into a full SDL replacement
- add sensors, rumble, battery, touchpad position, or player index in the first pass
- require bundling SDL's entire controller DB into core `wio`
- require changing the current `JoystickState` API

## Current constraints

`wio` already provides the right low-level primitive:

- enumerate joystick devices
- open a joystick
- poll raw state as axes / hats / buttons

That is enough to support a higher-level gamepad layer.

The main incompatibility with SDL mappings is device identity:

- SDL mappings are keyed by SDL GUID
- current `wio` device IDs are backend-specific, not SDL GUIDs

Examples today:

- Linux: vendor/product/version plus serial text
- Windows RawInput: interface path
- Windows XInput: `"xinput"`

So the real design problem is not the mapping parser. It is:

- how to identify a `wio` device using a stable SDL-compatible lookup key

## Design principle

Keep two kinds of identity separate:

### 1. Runtime identity

This is the identity used to track a live device inside the process.

Examples:

- current `wio` device ID string
- open joystick handle
- app-side device slot or registry key

This is for:

- connection tracking
- open/close bookkeeping
- associating a live `wio.Joystick` with gamepad state

### 2. Mapping identity

This is the identity used to choose an SDL mapping.

Examples:

- SDL GUID string
- `xinput`

This is for:

- DB lookup
- compatibility with SDL mapping text
- mapping overrides

These identities should not be forced into one field.

## Recommended architecture

Use a sidecar gamepad layer with its own API.

Suggested file split:

- `src/gamepad.zig`
- `src/gamepad_identity.zig`
- `src/gamepad_db.zig`
- `src/gamepad_runtime.zig`

The exact split can wait. The important part is that the gamepad layer owns:

- SDL mapping parsing
- SDL GUID generation or lookup
- gamepad DB storage
- runtime association between live `wio` devices and mappings
- raw-to-semantic translation

`wio` itself should remain responsible only for:

- device discovery
- low-level polling
- backend transport

## Public shape

The application-facing flow should look like this:

1. enumerate `wio.JoystickDevice`
2. ask gamepad layer to inspect the device
3. gamepad layer computes or retrieves an SDL GUID
4. gamepad layer looks up a mapping
5. app opens the `wio.Joystick`
6. app polls raw state
7. gamepad layer translates raw state into `GamepadState`

Possible API sketch:

```zig
const wio = @import("wio");
const gamepad = @import("gamepad");

var db: gamepad.Database = .{};
defer db.deinit(allocator);

try db.addMappingsFromText(allocator, my_db_text);

var device_iter = wio.JoystickDeviceIterator.init();
defer device_iter.deinit();

while (device_iter.next()) |device| {
    defer device.release();

    const info = try gamepad.identifyDevice(allocator, device);
    defer info.deinit(allocator);

    if (db.findGuid(info.sdl_guid)) |mapping| {
        if (device.open()) |joystick| {
            var js = joystick;
            defer js.close();

            const raw = js.poll() orelse continue;
            const state = mapping.mapState(raw);
            _ = state;
        }
    }
}
```

## Preferred layering

### Layer 1: raw `wio`

No semantic gamepad knowledge.

Existing API remains:

- `JoystickDevice`
- `Joystick`
- `JoystickState`

### Layer 2: identity adapter

This layer inspects a `wio.JoystickDevice` and constructs a mapping identity.

Output example:

```zig
pub const DeviceIdentity = struct {
    runtime_id: []u8,
    name: []u8,
    backend: Backend,
    vendor: ?u16,
    product: ?u16,
    version: ?u16,
    serial: ?[]u8,
    sdl_guid: []u8,
};
```

This is where most of the SDL-compatibility work belongs.

### Layer 3: mapping DB

This layer stores SDL-compatible mappings by GUID:

- built-in overrides
- user overrides
- project-specific DB
- future import of SDL DB text

### Layer 4: runtime translator

This layer binds:

- live `wio` joystick
- chosen mapping
- semantic `GamepadState`

## Options ranked by fork impact

## Option A: Zero `wio` changes

### Description

Do everything in the sidecar gamepad layer.

The gamepad layer uses current `wio` APIs only:

- `getId()`
- `getName()`
- `poll()`

and derives a best-effort SDL GUID from that.

### Pros

- no changes to upstream files
- easiest to rebase
- clean separation of responsibilities

### Cons

- GUID quality may be limited
- may require backend-specific heuristics outside `wio`
- may not match stock SDL DB entries accurately on all platforms

### When to choose it

Choose this first if your immediate goal is:

- building the higher-level API
- experimenting with mappings
- supporting your own curated DB

## Option B: Tiny raw-info hook in `wio`

### Description

Add one small, low-level device info API to `wio`, but keep all mapping logic
outside `wio`.

For example:

```zig
pub const JoystickInfo = struct {
    backend: Backend,
    bus: ?u16,
    vendor: ?u16,
    product: ?u16,
    version: ?u16,
    guid_crc: ?u16,
    driver_signature: ?u8,
    driver_data: ?u8,
};

pub fn getInfo(self: JoystickDevice) ?JoystickInfo
```

Or a narrower variant:

```zig
pub fn getVendorProductVersion(self: JoystickDevice) ?struct {
    vendor: u16,
    product: u16,
    version: u16,
}
```

### Pros

- still very small fork delta
- much better foundation for SDL GUID generation
- avoids duplicating backend probing in the sidecar layer

### Cons

- requires touching backend files
- still needs gamepad logic elsewhere

### When to choose it

Choose this if:

- zero-change GUID derivation proves too inaccurate
- you want better compatibility with stock SDL mapping DBs

This is the best compromise option.

## Option C: native SDL-GUID API in `wio`

### Description

Add something like:

```zig
pub fn getSdlGuid(self: JoystickDevice, allocator: std.mem.Allocator) ?[]u8
```

### Pros

- most convenient for the gamepad layer
- direct DB lookup

### Cons

- larger semantic commitment in `wio`
- pulls SDL policy into a raw input library
- more likely to diverge from upstream expectations

### When to choose it

Only if this fork is expected to permanently own SDL-compatible gamepad support
inside `wio`.

For minimizing changes, this is not the preferred option.

## Recommendation

Start with Option A, then move to Option B only if necessary.

That means:

1. keep the parser and semantic gamepad types in the sidecar layer
2. define a `DeviceIdentity` type outside `wio`
3. derive a best-effort SDL GUID there
4. track `runtime_id -> sdl_guid -> mapping`
5. only add a tiny raw-info hook to `wio` if lookup quality is not good enough

## Proposed sidecar types

## `DeviceIdentity`

```zig
pub const DeviceIdentity = struct {
    runtime_id: []u8,
    name: []u8,
    backend: Backend,
    vendor: ?u16 = null,
    product: ?u16 = null,
    version: ?u16 = null,
    serial: ?[]u8 = null,
    sdl_guid: []u8,
};
```

Purpose:

- carry both live-process identity and mapping identity
- allow richer heuristics later without breaking caller code

## `Database`

```zig
pub const Database = struct {
    // mappings keyed by SDL GUID
};
```

Purpose:

- store mappings from SDL-compatible text
- allow user overrides
- allow project-local DBs

## `GamepadBindingSet`

Optional internal type:

```zig
pub const GamepadBindingSet = struct {
    guid: []const u8,
    mapping: Mapping,
};
```

Purpose:

- decouple parsed mapping storage from runtime handles

## `GamepadDevice`

```zig
pub const GamepadDevice = struct {
    identity: DeviceIdentity,
    mapping: *const Mapping,
};
```

Purpose:

- represent a matched semantic device without modifying `wio.JoystickDevice`

## Runtime association

The runtime layer should maintain its own association table:

```zig
runtime_id -> {
    sdl_guid,
    mapping_index,
    last_known_name,
}
```

This lets the sidecar layer:

- refresh mappings when DB changes
- handle reconnects
- preserve user overrides

without requiring changes to `wio` handles.

## How to derive SDL GUIDs with minimal changes

There are two practical modes.

## Mode 1: best-effort GUID synthesis

Use whatever `wio` exposes today and encode a stable project-local GUID.

This would not need to exactly match SDL internals at first.

It only needs to be:

- deterministic
- stable enough for your project
- compatible with the SDL mapping string field shape

This mode is best for:

- curated project mappings
- local experimentation
- not depending on stock SDL DB coverage yet

## Mode 2: SDL-compatible GUID synthesis

If a small `wio` raw-info hook is added, generate GUIDs using:

- vendor
- product
- version
- backend/bus knowledge

This mode is best for:

- reusing stock SDL DB entries
- sharing mappings with SDL/raylib ecosystems

This mode should still live in the sidecar layer even if `wio` provides the raw pieces.

## Why not store SDL GUID in `wio.JoystickDevice.getId()`

Because `getId()` is already serving as a backend/runtime identifier, and
changing its semantics would:

- break assumptions in existing code
- make raw-device debugging less clear
- couple core `wio` to SDL policy

Better:

- keep `getId()` as-is
- compute mapping identity separately

## Minimal changes to existing `wio` files

The preferred plan can be implemented with:

- no edits to backend joystick code initially
- no changes to `JoystickState`
- no changes to `JoystickDevice.open()`

If one small hook is eventually needed, keep it low-level:

- backend enum
- vendor/product/version
- maybe bus/transport if cheaply available

Avoid:

- built-in controller DB in `wio`
- SDL parser inside backend files
- semantic button names in `JoystickState`

## Suggested phases

## Phase 1

- keep everything outside `wio`
- parser
- semantic state model
- project-local mapping DB
- runtime association using current `getId()`

This gives fast iteration with minimal fork cost.

## Phase 2

- add `DeviceIdentity`
- introduce best-effort GUID derivation
- support manual or curated SDL mapping entries

## Phase 3

- if needed, add tiny raw-info API to `wio`
- improve GUID derivation toward SDL compatibility
- test against stock SDL controller DB entries

## Decision

For this fork, the best design is:

- keep the gamepad abstraction in separate files and API
- do not fold SDL semantics into existing `wio` joystick types
- maintain a sidecar mapping identity based on SDL GUID strings
- keep `wio` runtime IDs and SDL mapping IDs separate
- only add a tiny raw metadata hook to `wio` if necessary for compatibility

This gives the smallest upstream diff while still making SDL mapping support
practical.

## Chosen option

We chose **Option B: Tiny raw-info hook in `wio`**.

That means:

- SDL mapping logic remains outside core `wio`
- `wio` exposes only low-level joystick metadata
- the sidecar gamepad layer consumes that metadata to build SDL-style mapping
  identities

This keeps the fork relatively close to upstream while avoiding the main
problem with Option A, which was weak device identity for SDL mapping lookup.

## Current status

### Implemented

The following work is done:

- analysis doc added:
  - `gamepad-api-analysis.md`
- design doc added:
  - `gamepad-layer-design.md`
- sidecar gamepad module added:
  - `src/gamepad.zig`
- small `wio` raw-info API added:
  - `wio.JoystickBackend`
  - `wio.JoystickInfo`
  - `JoystickDevice.getInfo()`
- backend `getInfo()` implementations added for:
  - Linux evdev
  - macOS IOKit
  - Windows RawInput
  - Windows XInput
  - WebAssembly
  - Haiku
  - null / Android stubs
- sidecar device identity support added:
  - `gamepad.DeviceIdentity`
  - `gamepad.identifyDevice()`
- SDL-style GUID synthesis added in the sidecar layer
  - bus/vendor/product/version packing
  - SDL-compatible name CRC packing
  - optional low-level driver signature/data bytes
- SDL-compatible mapping parser added
- semantic gamepad state translation added
- sidecar runtime handle added:
  - `gamepad.GamepadDevice`
  - `GamepadDevice.open()`
  - `GamepadDevice.poll()`
- test step added to `build.zig`
- tests added and passing for:
  - mapping parsing
  - half-axis and inverted-axis handling
  - SDL-style GUID synthesis
  - SDL-compatible CRC16 generation
  - loading and matching a real SDL DB subset
  - SDL-style CRC and version fallback during DB lookup
  - representative SDL DB matches for 8BitDo, PS5, Xbox One, and Xbox
    Bluetooth entries

### Verified

The following command passes:

```text
zig build test
```

### Important limitation

The current GUID synthesis is a practical SDL-style approximation based on the
new raw metadata hook.

It is good enough for:

- `xinput`
- USB/Bluetooth-style vendor/product/version devices
- SDL-style name CRC matching
- low-level driver signature/data bytes when a backend exposes them
- curated project mappings
- initial SDL DB subset matching

It is not yet proven to be byte-for-byte compatible with SDL's GUID generation
for all devices and all backends.

The first SDL DB compatibility sweep also found one concrete remaining
limitation: Android-style SDL mappings use button and axis capability masks in
the final GUID bytes. Android is not a priority for this pass, so the current
sidecar does not try to synthesize those capability-mask GUIDs. If Android
support becomes important later, expose those masks from the Android backend
instead of guessing them from desktop joystick state.

## Next steps

The next recommended work is:

### 1. Continue SDL DB compatibility sweep

Test more real SDL mapping entries across more device families and backend
variants:

- Xbox Series / BLE variants with driver-specific GUID tails
- PlayStation edge cases and third-party PS5 controllers
- Nintendo variants
- additional 8BitDo and other third-party controllers

This will show where current GUID synthesis still differs from SDL enough to
break lookup.

### 2. Metadata / GUID refinement if needed

If the broader sweep reveals lookup gaps, refine the sidecar GUID synthesis
first.

Only if necessary, consider very small additions to the raw `JoystickInfo`
hook, such as:

- better bus/transport distinction
- additional backend-discoverable raw identifiers
- Android button/axis capability masks, if Android SDL DB parity becomes a
  priority

### 3. Split `src/gamepad.zig`

Once the runtime layer starts growing, split the sidecar code into smaller
files:

- identity
- mapping parser / DB
- runtime
- translation

## Resume point for tomorrow

The current foundation and first runtime handle are complete and verified.

The next task to start with is:

- continue the SDL DB compatibility sweep, focusing on non-Android GUID
  variants that need metadata beyond bus/vendor/product/version/CRC

Suggested starting point:

1. inspect Xbox Series Bluetooth/BLE entries with nonzero final GUID bytes
2. determine whether those bytes come from HIDAPI driver data or another
   desktop backend-specific source
3. decide whether to expose a tiny raw metadata extension or leave those entries
   to curated/project mappings
