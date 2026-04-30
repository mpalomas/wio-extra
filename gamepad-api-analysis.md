# SDL3 Gamepad API and `wio` Joystick API

## Summary

SDL3's gamepad API is a semantic layer on top of raw joystick input.

`wio` currently exposes raw joystick state:

- variable-length `axes`
- variable-length `hats`
- variable-length `buttons`

SDL3 instead exposes canonical gamepad controls:

- face buttons
- dpad
- stick buttons
- shoulders
- triggers
- left/right stick axes
- optional extra buttons such as paddles, touchpad, share/capture

The key SDL concept that enables this is the **mapping**.

## What SDL means by "mapping"

An SDL mapping is a per-device translation from raw joystick controls to
canonical gamepad controls.

Examples:

- raw button 5 -> `start`
- raw axis 0 -> `leftx`
- raw hat 0 / up -> `dpup`
- raw positive half of axis 4 -> `lefttrigger`

SDL describes this publicly in:

- `/Users/mpalomas/dev/c++/SDL/include/SDL3/SDL_gamepad.h`

The relevant parts are:

- `SDL_GamepadBindingType`
- `SDL_GamepadBinding`
- `SDL_AddGamepadMapping()`
- `SDL_AddGamepadMappingsFromFile()`

The implementation is in:

- `/Users/mpalomas/dev/c++/SDL/src/joystick/SDL_gamepad.c`

The built-in mapping database is in:

- `/Users/mpalomas/dev/c++/SDL/src/joystick/SDL_gamepad_db.h`

## Mapping string format

SDL mapping strings are text entries of the form:

```text
GUID,name,mapping...
```

Example from SDL docs:

```text
341a3608000000000000504944564944,Afterglow PS3 Controller,a:b1,b:b2,y:b3,x:b0,start:b9,guide:b12,back:b8,dpup:h0.1,dpleft:h0.8,dpdown:h0.4,dpright:h0.2,leftshoulder:b4,rightshoulder:b5,leftstick:b10,rightstick:b11,leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:b6,righttrigger:b7
```

Raw input side tokens:

- `bX`: raw button `X`
- `aX`: raw axis `X`
- `hX.Y`: raw hat `X` with mask/value `Y`

Useful SDL extensions used in real DB entries:

- `+aX`: positive half of axis `X`
- `-aX`: negative half of axis `X`
- `aX~`: inverted axis
- `crc:xxxx`: distinguish firmware/layout variants with same GUID
- `platform:...`: limit to a platform
- `type:...`: gamepad type hint
- `face:...`: button face-style hint
- `hint:...`: compatibility / label hints

## Why SDL needs a mapping DB

Raw joystick layouts are not stable across:

- OS APIs
- drivers
- firmware versions
- Bluetooth vs USB
- vendor implementations

Without a mapping layer, applications end up either:

- hardcoding lots of special cases, or
- asking users to remap everything manually

SDL centralizes this work into a database plus a parser plus a canonical output
model.

## How SDL uses mappings

At runtime SDL:

1. Identifies the device using a GUID.
2. Searches for the best mapping.
3. Parses the mapping into `SDL_GamepadBinding` records.
4. Converts raw joystick input into canonical gamepad events/state.

The matching logic in `SDL_gamepad.c` tries:

1. exact GUID + version + CRC
2. exact GUID + version without CRC
3. GUID without version with/without CRC
4. special fallback handling for XInput / HIDAPI / WGI / generated mappings

This is why SDL's gamepad layer works for a very large set of controllers while
still presenting a stable API to the application.

## SDL3 semantic model

SDL3 intentionally uses positional face buttons in the public API:

- south
- east
- west
- north

This avoids baking Xbox button letters into the public model.

The mapping strings still use the historical `a,b,x,y` names, but SDL derives
face style and labels separately for Nintendo, PlayStation, GameCube, etc.

That distinction matters if a project wants:

- correct on-screen prompts
- region-sensitive accept/cancel behavior
- support for Nintendo/GameCube-style layouts

## raylib comparison

raylib exposes a much smaller public API:

- `IsGamepadAvailable()`
- `GetGamepadName()`
- button state queries
- `GetGamepadAxisCount()`
- `GetGamepadAxisMovement()`
- `SetGamepadMappings()`

Its public API stays simple, but it still accepts SDL GameControllerDB-style
mappings. That is a useful middle ground:

- simple application-facing API
- shared mapping format

## Current `wio` joystick API

`wio` currently exposes:

- joystick enumeration
- `JoystickDevice.getId()`
- `JoystickDevice.getName()`
- `Joystick.poll() -> JoystickState`

`JoystickState` is:

```zig
pub const JoystickState = struct {
    axes: []const u16,
    hats: []const Hat,
    buttons: []const bool,
};
```

That is a raw device model, not a semantic gamepad model.

## Gaps between SDL3 Gamepad and current `wio`

### 1. No canonical control names

`wio` callers only get numbered axes/buttons/hats.

There is no stable meaning such as:

- `leftx`
- `righttrigger`
- `south`
- `start`

### 2. No mapping database

There is no built-in or user-loadable database that translates device IDs into
semantic bindings.

There is also a more specific compatibility problem: current `wio`
`JoystickDevice.getId()` values are not SDL-style GUIDs on most backends.

Examples:

- Linux currently returns vendor/product/version plus serial text.
- Windows RawInput currently returns the device interface path.
- Windows XInput currently returns `"xinput"`.

That means an SDL mapping parser alone is not enough to consume the standard
SDL mapping DB automatically. A proper SDL-compatible gamepad layer in `wio`
also needs a backend-neutral device GUID story.

### 3. No cross-device layout normalization

Each backend returns its own raw ordering.

Examples:

- Linux enumerates evdev absolute axes and keys dynamically.
- Windows XInput returns a hardcoded Xbox-like layout.
- Windows RawInput returns HID-discovered controls.

Those are not a single stable contract.

### 4. No gamepad type / face-style information

`wio` cannot currently tell the caller whether a device should be presented as:

- Xbox
- PlayStation
- Switch
- GameCube

### 5. No support for semantic extras

SDL includes optional semantic controls beyond the basic set:

- paddles
- touchpad button
- share/capture/mic/misc buttons
- sensors
- touchpads
- rumble
- battery
- player index

`wio` exposes none of those at the semantic layer.

### 6. No remapping pipeline

SDL lets applications or users:

- load new mappings
- override existing mappings
- reload the DB

`wio` currently has no equivalent mechanism.

## What `wio` needs if it wants broad controller support

The existing joystick layer is still useful. It should remain the raw backend.

On top of it, `wio` needs a gamepad translation layer with:

1. a canonical gamepad state model
2. an SDL-compatible mapping parser
3. a mapping database keyed by device ID
4. translation from `JoystickState` to `GamepadState`
5. room for optional metadata such as type / face style / platform

## Recommended direction for this repo

### Keep the raw joystick API

Do not replace `JoystickState`.

It is the right primitive for:

- unusual devices
- debugging
- custom remapping UIs
- non-gamepad controllers

### Add a gamepad layer above it

Add a separate module that:

- parses SDL-compatible mapping strings
- stores mappings in a DB
- matches mappings by device ID
- converts raw joystick state into semantic gamepad state

In practice this should be split into two stages:

1. SDL-compatible mapping parsing and state translation
2. backend work to expose SDL-like stable IDs / GUIDs for DB lookup

### Reuse SDL's format instead of inventing a new one

That gives immediate benefits:

- existing controller DBs are usable
- generated SDL mappings are reusable
- users already familiar with SDL mappings can supply fixes

## Scope for a first implementation

A practical first version should support:

- face buttons
- dpad
- back / guide / start
- stick buttons
- shoulders
- triggers
- left/right stick axes
- `misc1..misc6`
- `paddle1..paddle4`
- `touchpad`

And on the parser side:

- `bX`
- `aX`
- `hX.Y`
- `+aX`
- `-aX`
- `aX~`
- metadata fields preserved but not necessarily all enforced

## Outcome

The right model for this repo is:

- `wio.Joystick`: raw
- `wio.gamepad`: semantic

That is much closer to SDL's strengths while keeping `wio` small and explicit.
