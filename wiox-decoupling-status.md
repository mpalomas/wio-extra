# Wiox Decoupling Status

## Goal

Reduce long-term merge conflicts with upstream `wio` by moving fork-only display and gamepad functionality out of core `wio` files and into a sidecar extension module.

Target shape:

- `wio` stays as close as possible to upstream responsibilities.
- fork-only APIs live under `wiox`.
- platform-specific extension code lives in new `src/wiox/**` files.
- changes to existing upstream-owned files are minimized and localized.

## Implemented

### New sidecar module

- Added `src/wiox.zig`
- Added `wiox.display`
- Added `wiox.gamepad`
- Updated `build.zig` to expose a separate `wiox` module alongside `wio`

### Display moved out of core

Moved display implementation into:

- `src/wiox/display.zig`
- `src/wiox/display/types.zig`
- `src/wiox/display/stub.zig`
- `src/wiox/display/macos.zig`
- `src/wiox/display/win32.zig`
- `src/wiox/display/wayland.zig`
- `src/wiox/display/wayland_math.zig`
- `src/wiox/macos_display.m`

Removed old core display files:

- `src/display.zig`
- `src/display_types.zig`
- `src/display_stub.zig`
- `src/macos_display.zig`
- `src/win32_display.zig`
- `src/unix/wayland_display.zig`
- `src/unix/wayland_display_math.zig`

### Gamepad moved out of core

Moved SDL-style gamepad layer into:

- `src/wiox/gamepad.zig`

Removed old core gamepad file:

- `src/gamepad.zig`

### Core API trimmed back down

Removed fork-only surface from `src/wio.zig`:

- `wio.gamepad`
- display re-exports
- `Window.getDisplay()`
- joystick metadata API used only by the gamepad layer

Removed backend metadata hooks that were only present for gamepad GUID synthesis:

- `src/win32.zig`
- `src/macos.zig`
- `src/unix/joystick/linux.zig`
- `src/unix/joystick/null.zig`
- `src/android.zig`
- `src/haiku.zig`
- `src/wasm.zig`

### Wayland display ownership moved out of core

`src/unix/wayland.zig` no longer owns the display sidecar lifecycle. The sidecar display module now owns its own registry/output tracking logic and uses the existing shared Wayland connection.

## Current Status

### Working

- `zig build test` passes
- `wio` no longer exposes the fork display/gamepad surface
- `wiox` is the new extension entrypoint
- display/gamepad code is mostly isolated in new sidecar files

### Remaining intentional core diffs

Some changes still remain in upstream-owned files because they are not display/gamepad-specific and were already part of the branch:

- relative mouse / cursor API changes
- other previously landed backend adjustments unrelated to this isolation pass

## Display Test Status

### Current state

Display tests are wired back into the default `zig build test` step.

The fix was:

- stop importing the full `wiox` root from the display test target
- add a dedicated `wiox_display` test module rooted at `src/wiox/display.zig`
- force the stub backend for that test module via build options

That keeps display tests sidecar-owned and avoids pulling the full `wio` backend glue into the display-only test binary.

### What the current test target covers

- display API shape
- display value types
- stub backend contract
- Wayland display math module compile path

### Remaining limitation

The restored display test target currently forces the stub backend rather than linking the real platform display backend implementations.

That is intentional:

- it keeps `zig build test` reliable across platforms
- it avoids macOS/X11/Wayland runtime linkage issues in a unit-test target
- it still validates the sidecar display API surface and core pure-Zig logic

If real-backend display tests are wanted later, they should likely be added as separate integration-style test steps rather than folded into the default unit-test path.

## Suggested Follow-up

1. Update README and examples to document `wiox` imports.
2. Reintroduce a dedicated display test target once the test/build split is cleaned up.
3. Optionally split `src/wiox/gamepad.zig` into smaller files after the interface settles.
