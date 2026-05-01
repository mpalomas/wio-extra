# Window Display Association Plan

## Summary

`wio` can currently enumerate displays and report:

- desktop bounds
- usable bounds
- content scale
- current pixel mode size
- refresh rate

`wio` can also report per-window events for:

- logical size
- physical size
- scale

What `wio` does not currently expose is the missing link between those two worlds:

- which display a given window is on
- which displays a given window intersects
- the window's global desktop position

That means applications can know:

- what displays exist
- what scale the current window ended up using

But applications cannot reliably know:

- which exact display is driving that scale
- whether the window moved to another display
- which display should be used when deriving an initial logical size for a target framebuffer size

This matters for DPI-aware window creation. Before a window exists, the application wants to choose a logical size that will produce a desired framebuffer size. After the window exists, the application may want to know whether that choice should be recomputed because the window is now on another display with another scale.

## Current State In `wio`

### What the public API already exposes

- `DisplayIterator`
- `Display.getCurrentMode()`
- `Display.getBounds()`
- `Display.getUsableBounds()`
- `Display.getContentScale()`
- window events: `size_logical`, `size_physical`, `scale`

Relevant files:

- [`src/wio.zig`](src/wio.zig)
- [`src/display_types.zig`](src/display_types.zig)
- [`src/display.zig`](src/display.zig)

### What the public API does not expose

- `Window.getPosition()`
- `Window.setPosition()`
- `Window.getDisplay()`
- `Window.getDisplays()`
- a window event reporting display/output enter/leave

So bounds-based inference is blocked today because applications do not know the window rectangle in global desktop coordinates.

## What Is Possible Today

### Before creating a window

Only a weak guess is possible.

The application may:

- enumerate all displays
- choose one display as the presumed initial target
- use that display's `content_scale` to derive a logical size

This is what the `triangle.zig` example currently does when it uses display `0` as a best-effort guess.

Limitations:

- the chosen display may not be the one where the compositor or window manager places the new window
- multiple displays may share the same scale, so scale alone is not enough to identify the actual display
- on Wayland, exact placement is generally compositor-controlled and not something the client should expect to know ahead of time

### After creating a window

The application can observe:

- `scale`
- `size_logical`
- `size_physical`

This is enough to know whether the framebuffer size is what was requested.

This is not enough to know:

- which display the window is on
- whether the window overlaps multiple displays

## Platform Analysis

## Wayland

### What exists today

The Wayland display backend already tracks outputs and exposes:

- logical output bounds via `xdg-output` when available
- integer `wl_output.scale`
- fractional content scale derived from native pixel size versus logical size

Relevant files:

- [`src/unix/wayland_display.zig`](src/unix/wayland_display.zig)
- [`src/unix/wayland_display_math.zig`](src/unix/wayland_display_math.zig)

The Wayland window backend already tracks:

- logical window size
- physical framebuffer size
- scale changes

Relevant file:

- [`src/unix/wayland.zig`](src/unix/wayland.zig)

### What is missing

The current Wayland window backend does not track `wl_surface.enter` / `wl_surface.leave` output membership for each window surface.

That is the key missing primitive.

### Can we guess from bounds?

Not well, and not portably.

Wayland is the least suitable platform for geometry-based guessing because:

- global window position is not a stable client-facing concept
- initial placement is compositor-controlled
- clients should not rely on being able to reconstruct exact monitor placement from desktop coordinates

### Correct Wayland direction

The correct Wayland solution is not "guess from bounds".

The correct solution is:

- track `wl_surface.enter`
- track `wl_surface.leave`
- maintain the set of `wl_output`s currently intersecting the surface
- map those `wl_output`s back to `wio.Display` handles

This would support:

- exact current output membership
- exact notification when the window moves across outputs
- correct scale selection logic for the display actually affecting the surface

### Recommendation for Wayland

If `wio` wants to support this well, it should expose more backend information through a backend-neutral API, not ask applications to guess.

Best design direction:

- add a public API that tells which display or displays a window is on
- implement it on Wayland using `wl_surface.enter` / `leave`

## X11

### What exists today

X11 does provide enough information to infer the display from geometry:

- display bounds are already exposed by the display API
- window `ConfigureNotify` contains window geometry information
- the backend already has X11 primitives available for window coordinate work

Relevant file:

- [`src/unix/x11.zig`](src/unix/x11.zig)

### What is missing

The public API does not expose the window's global position.

The backend currently pushes size and mode updates, but not global desktop coordinates for the window.

### Can we guess from bounds?

Yes, on X11 this is practical if `wio` exposes enough geometry.

Reasonable strategy:

- get the window rect in desktop coordinates
- intersect that rect with each display's bounds
- choose the display with the largest overlap
- if overlap is ambiguous or zero, fall back to nearest window center

This is a good inference model on X11.

### Recommendation for X11

Two viable options:

- expose window global position and let applications infer the display
- or expose a direct `Window.getDisplay()` style API implemented in the backend

If `wio` wants a single portable API, direct backend support is preferable.

## Win32

### What exists today

Win32 has a direct native answer for "which monitor is this window on":

- `MonitorFromWindow`

The backend already uses this for fullscreen placement.

Relevant file:

- [`src/win32.zig`](src/win32.zig)

### What is missing

The public `wio` API does not expose the result.

### Can we guess from bounds?

Yes, but on Win32 there is little reason to guess because the native API already answers the question directly.

### Recommendation for Win32

Expose a direct display query in `wio`.

This is likely the easiest backend to support first.

## macOS

### What exists today

The macOS backend already exposes display enumeration and scale via the display API.

Relevant file:

- [`src/macos_display.zig`](src/macos_display.zig)

Cocoa also has the notion of the screen associated with a window.

### What is missing

The public `wio` API does not expose window-to-screen association.

### Can we guess from bounds?

Probably yes if window geometry is exposed, but on macOS there is also a native concept of the current screen, so direct backend support is preferable.

### Recommendation for macOS

Expose direct window-to-display association from the backend rather than asking applications to infer it manually.

## What Should Be Added To `wio`

## Preferred API Direction

The best portable API is not just a window position getter.

The best portable API is a display association API.

Candidate shapes:

```zig
pub fn getDisplay(self: *Window) ?Display;
pub fn getDisplays(self: *Window, allocator: std.mem.Allocator) ![]Display;
```

Possible event-based extension:

```zig
display_changed: void,
```

Or, if multi-display overlap should be observable:

```zig
displays_changed: void,
```

The exact shape can be decided during implementation, but the important point is:

- applications should be able to query the display actually associated with the window
- Wayland should not depend on guessed global geometry

## Alternative API Direction

Expose only geometry primitives:

```zig
pub fn getPosition(self: *Window) ?BoundsOrPosition;
```

Then let applications infer the display from bounds.

This is weaker:

- it still does not solve Wayland cleanly
- every application would need to reimplement overlap heuristics
- the heuristic behavior would differ across applications

This is acceptable as a supplementary API, but not as the main solution.

## Recommended Semantics

If `Window.getDisplay()` is added, it should mean:

- the display most relevant to the window at the moment of the query

Suggested backend interpretation:

- Win32: result of `MonitorFromWindow`
- macOS: current screen for the NSWindow
- X11: display with largest overlap against the window rect
- Wayland: preferred output derived from surface output membership

If `Window.getDisplays()` is added, it should mean:

- all displays currently intersecting the window surface or window rect

This would be especially useful for:

- large windows spanning multiple displays
- debugging scale transitions
- choosing the "best" display in application policy code

## Practical Guidance For The Triangle Example

Today:

- pre-create sizing can only use a guessed display scale
- post-create verification can use the actual `size_physical` event to confirm the framebuffer result

Tomorrow, with a better API:

- create the window using a best-effort initial scale
- query the actual display after mapping
- if needed, recompute the desired logical size and resize once

That would be a pragmatic cross-platform model even if exact pre-create placement cannot always be known.

## Implementation Plan For Tomorrow

1. Decide the public API shape.
2. Implement backend support on Win32 first, since native support already exists.
3. Implement backend support on macOS using the window's current screen.
4. Implement backend support on X11 using window rect versus display bounds.
5. Implement backend support on Wayland using `wl_surface.enter` / `wl_surface.leave`.
6. Add a small demo or example log that shows:
   - guessed initial display scale
   - actual display after map
   - resulting framebuffer size

## Final Recommendation

For a real solution, `wio` should expose window-to-display association explicitly.

Summary by platform:

- Wayland: guessing is the wrong model; use surface output membership
- X11: guessing from geometry is feasible, but should live inside `wio`, not every application
- Win32: direct native answer already exists
- macOS: direct native answer should exist through Cocoa screen association

So the implementation direction should be:

- add a public API for current window display association
- use geometry only where the platform model requires it
- use native direct monitor/screen/output association where the platform already provides it
