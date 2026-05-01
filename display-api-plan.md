# Display API Plan

## Summary

Add a small, query-only display API that follows `wio`'s existing iterator-and-handle style while covering the SDL3-style display subset needed on macOS:

- enumerate connected displays
- query the current display mode only
- expose desktop bounds, usable/work area, content scale, physical mode resolution, and accurate refresh rate
- keep merge surface small by putting almost all new code in new files and limiting existing-file edits to short append-only imports plus macOS helper exports at the bottom of `src/macos.m`

## Public API

Add the public API in a new file, then append one line near the bottom of `src/wio.zig` to re-export it, preferably with `pub usingnamespace @import("display.zig");`.

Proposed public surface:

```zig
pub const DisplayIterator = struct {
    pub fn init() DisplayIterator;
    pub fn deinit(self: *DisplayIterator) void;
    pub fn next(self: *DisplayIterator) ?Display;
};

pub const Display = struct {
    pub fn release(self: Display) void;

    pub fn getCurrentMode(self: Display) ?DisplayMode;

    pub fn getBounds(self: Display) ?Bounds;
    pub fn getUsableBounds(self: Display) ?Bounds;
    pub fn getContentScale(self: Display) f64;
    pub fn getRefreshRate(self: Display) RefreshRate;
};

pub const Bounds = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RefreshRate = struct {
    hz: f64,
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
```

API decisions locked in:

- Use `DisplayIterator`, not an allocated top-level slice API.
- Keep `Display` as a lightweight handle, matching joystick/audio device patterns.
- Make `getCurrentMode()` the canonical source of data.
- Keep SDL-like convenience methods on `Display` for the required subset; they delegate to current-mode queries.
- Use signed coordinates for bounds because monitor layouts can be negative.
- Use `u32` sizes for display geometry instead of existing `wio.Size`, because `wio.Size` is `u16` and is window-oriented.
- `release()` is a no-op on macOS initially, but keep it for API consistency and future backend flexibility.

## Implementation Changes

### Public/API layer

Create `src/display.zig`:

- define `Bounds`, `RefreshRate`, `DisplayMode`, `DisplayIterator`, and `Display`
- select a display backend with `const display_backend = if (@hasDecl(backend, "DisplayIterator")) backend else @import("display_stub.zig");`
- keep this isolated from the rest of `wio.zig` so the only existing-file change is a bottom-of-file re-export

Create `src/display_stub.zig`:

- no-op fallback for platforms without display support yet
- returns empty iterator / null mode / zero refresh rate
- avoids touching every existing backend file now

### macOS backend

Create `src/macos_display.zig`:

- implement `pub const DisplayIterator`
- implement `pub const Display`
- declare only the extern functions needed for display querying
- append one line near the bottom of `src/macos.zig` to re-export it, preferably `pub usingnamespace @import("macos_display.zig");`

Append macOS helper functions at the bottom of `src/macos.m`:

- enumerate `NSScreen.screens`
- map each screen to `CGDirectDisplayID` through `deviceDescription[@"NSScreenNumber"]`
- expose screen frame, visible frame, backing scale factor, and localized lookup helpers if needed
- keep all new Objective-C additions below current code to reduce conflict risk

Add one small macOS build change in `build.zig`:

- link `CoreVideo` on macOS, because precise rational refresh data should come from `CVDisplayLink`

### macOS query strategy

For each display handle:

- Identity:
  - store `CGDirectDisplayID` in the backend handle
  - `Display.backend` remains publicly accessible, matching current platform-specific `wio` style

- List connected displays:
  - enumerate `NSScreen.screens`
  - preserve AppKit order
  - store matching `CGDirectDisplayID`s in an allocated slice inside the iterator
  - `deinit()` frees only that slice

- Bounds:
  - use `NSScreen.frame`
  - convert `NSRect` to `Bounds`
  - these coordinates stay in AppKit desktop coordinates, which align with `visibleFrame` and content scale

- Usable/work area:
  - use `NSScreen.visibleFrame`
  - convert to `Bounds`
  - keep same coordinate space as `bounds`

- Content scale:
  - use `NSScreen.backingScaleFactor`
  - expose as `f64`

- Physical resolution of current mode:
  - use `CGDisplayCopyDisplayMode`
  - read `CGDisplayModeGetPixelWidth` and `CGDisplayModeGetPixelHeight`
  - release the mode object after reading

- Refresh rate:
  - preferred path: `CVDisplayLinkCreateWithCGDisplay` + `CVDisplayLinkGetNominalOutputVideoRefreshPeriod`
  - convert the returned period to rate:
    - if period is `timeValue / timeScale`, then rate is `timeScale / timeValue`
    - reduce to `u32` numerator/denominator when representable
    - compute `hz` from the rational
  - fallback path: `CGDisplayModeGetRefreshRate` when the CoreVideo period is unavailable, indefinite, zero, or unusable
  - when only fallback works, set `hz` and leave `numerator = 0`, `denominator = 0`

Behavioral constraints:

- query-only; no setters, no mode switching, no events
- snapshot semantics; each call reads live system state
- current mode only; no full mode enumeration yet
- no guarantee that a previously fetched `Display` survives physical unplug/reconfiguration across arbitrary future calls

### Wayland backend

The Linux Wayland backend follows SDL3's default Wayland display semantics:

- `bounds` are desktop/global-compositor coordinates, not physical pixels.
- `pixel_width` / `pixel_height` carry the current native output mode in physical pixels.
- `content_scale` describes the relationship between desktop coordinate units and physical pixels.
- `usable_bounds` currently equals `bounds`, because core Wayland does not expose a portable reserved-work-area concept for panels, docks, or bars.

This means a 2560x1440 output at 200% scale should normally report:

```text
bounds: 1280x720
content_scale: 2.0
pixels: 2560x1440
```

For fractional scaling, the integer `wl_output.scale` value is not sufficient. A compositor may advertise `wl_output.scale = 2` while its actual logical output size corresponds to a fractional scale such as 1.15. In that case, relying only on `wl_output.mode / wl_output.scale` would incorrectly report 1280x720 for a 2560x1440 monitor, while the compositor's logical size might be closer to 2227x1252.

Implementation details:

- Track each `wl_output` announced by the registry.
- Listen to core `wl_output` events:
  - `geometry`: fallback position and transform
  - `mode`: current physical pixel mode and millihertz refresh rate
  - `scale`: integer fallback scale
- Bind `zxdg_output_manager_v1` when available.
- For each output, create a `zxdg_output_v1` object and prefer its:
  - `logical_position` for `bounds.x` / `bounds.y`
  - `logical_size` for `bounds.width` / `bounds.height`
- Compute `content_scale` as:
  - `transformed_native_pixel_width / xdg_logical_width` when xdg-output logical size is available
  - otherwise the integer `wl_output.scale`
- Account for rotated outputs when reporting physical pixel width/height and when deriving fallback logical bounds.
- Convert Wayland refresh from millihertz into both:
  - `hz = refresh_millihz / 1000.0`
  - a reduced rational numerator/denominator when available

Initialization detail:

- After binding registry globals, perform a second `wl_display_roundtrip`.
- The first roundtrip discovers globals and creates `zxdg_output_v1` objects.
- The second roundtrip lets the compositor deliver xdg-output logical geometry before display queries immediately after `wio.init()`.

Known limitations:

- There is no xdg-output fallback for compositors that do not support `zxdg_output_manager_v1`; those use integer `wl_output.scale`.
- The backend does not implement SDL's optional `SDL_VIDEO_WAYLAND_SCALE_TO_DISPLAY=1` behavior, which reports pixel-space display bounds for legacy non-DPI-aware apps. `wio` should keep logical bounds as the default API semantics.
- There is no mode switching or full mode enumeration.
- Hotplug removal marks a display handle disconnected; handles fetched before reconfiguration should not be assumed valid forever.

## Test Plan

Add coverage sufficient for implementation acceptance:

- compile on macOS with the new API enabled in default configuration
- smoke test:
  - iterate displays
  - ensure at least one display on a normal macOS desktop
  - ensure `getCurrentMode()` succeeds for each enumerated display
- geometry checks:
  - `bounds.width > 0`, `bounds.height > 0`
  - `usable_bounds.width > 0`, `usable_bounds.height > 0`
  - `usable_bounds` does not exceed `bounds`
- scale checks:
  - `content_scale >= 1.0`
- refresh checks:
  - `hz > 0` on common external/internal displays
  - if rational is present, `abs(hz - numerator / denominator)` stays within a small epsilon
- retina sanity check:
  - on a HiDPI display, `pixel_width` and `pixel_height` should reflect physical mode size, not AppKit point size
- fallback check:
  - implementation behaves correctly when rational refresh info is unavailable and only `hz` can be returned
- Wayland API/unit checks:
  - display API shape compiles through a dedicated display test root
  - Wayland integer-scale fallback converts native pixels to logical bounds
  - Wayland rotated outputs swap physical width/height where appropriate
  - Wayland xdg-output logical size wins over integer `wl_output.scale`
  - fractional content scale is computed from native pixels divided by xdg-output logical width

## Assumptions

- The initial API was macOS-first; macOS, Win32, and Linux Wayland now have concrete backends.
- `Bounds` are desktop coordinate units, not physical pixels. On macOS these are AppKit coordinates; on Wayland these are logical compositor coordinates.
- Physical pixel resolution is carried separately as `pixel_width` / `pixel_height`.
- `Display.release()` exists for consistency even when it is a no-op.
- `display-api-plan.md` should live at repo root to avoid creating a new docs tree.
- Using deprecated CoreVideo display-link refresh APIs is acceptable here because the repo already suppresses deprecated macOS warnings in `src/macos.m`, and this path gives the best exact refresh rational currently available.

## References

- SDL display subset inspiration:
  - https://wiki.libsdl.org/SDL3/CategoryVideo
  - https://wiki.libsdl.org/SDL3/SDL_GetDisplays
  - https://wiki.libsdl.org/SDL3/SDL_GetDisplayBounds
  - https://wiki.libsdl.org/SDL3/SDL_GetDisplayUsableBounds
  - https://wiki.libsdl.org/SDL3/SDL_GetDisplayContentScale
  - https://wiki.libsdl.org/SDL3/SDL_GetCurrentDisplayMode
  - https://wiki.libsdl.org/SDL_DisplayMode
- macOS implementation sources:
  - `NSScreen.deviceDescription` / `NSScreenNumber`: https://developer.apple.com/documentation/appkit/nsscreen/devicedescription
  - `NSScreen.frame`: https://developer.apple.com/documentation/appkit/nsscreen/frame
  - `NSScreen.visibleFrame`: https://developer.apple.com/documentation/appkit/nsscreen/visibleframe
  - `NSScreen.backingScaleFactor`: https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor
  - `CGGetActiveDisplayList`: https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist%28_%3A_%3A_%3A%29
  - `CGDisplayBounds`: https://developer.apple.com/documentation/coregraphics/1456395-cgdisplaybounds
  - `CGDisplayCopyDisplayMode`: https://developer.apple.com/documentation/coregraphics/cgdisplaycopydisplaymode%28_%3A%29
  - `CGDisplayModeGetRefreshRate`: https://developer.apple.com/documentation/coregraphics/cgdisplaymode/refreshrate
  - `CVDisplayLinkGetNominalOutputVideoRefreshPeriod`: https://developer.apple.com/documentation/corevideo/cvdisplaylinkgetnominaloutputvideorefreshperiod%28_%3A%29
- Wayland implementation sources:
  - `wl_output` core protocol
  - `xdg-output-unstable-v1`
  - SDL3 Wayland backend comparison in local checkout: `/home/michael/dev/c++/SDL/src/video/wayland/SDL_waylandvideo.c`
