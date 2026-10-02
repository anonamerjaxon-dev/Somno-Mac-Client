# CursorFX (CursorChanger)

System-wide custom cursor replacement for macOS. Replaces the stock arrow,
ibeam, pointing hand, and more with custom PNG/SVG artwork — system-wide,
in every app, with pixel-exact hotspots.

This is an **original implementation** built from the ground up. We studied the
private CGS cursor API surface that Mousecape and MaCursor documented, but our
registration strategy, enforcement model, state-mapping tables, image pipeline,
and scale-bump refresh trick are our own design.

## How it works

Custom cursor images are registered into WindowServer's cursor registry via
private CoreGraphics APIs (`CGSRegisterCursorWithImages`). The images *become*
the real system cursor — no overlay window, no rendering latency, and click
accuracy follows the declared hotspot.

- Registration lives in WindowServer memory only — reverts on logout/reboot.
- No SIP modification, no kexts, nothing outside user-space folders.
- Uses dlopen/dlsym to bridge private CGS symbols at runtime — no compiled C
  interop targets needed.
- After macOS major releases, identifier tables and symbol offsets may need
  reverification.

## ⚠️ Known Issue — Cursor Reversion (Sept 2026)

**Custom cursors only render during transitional/interstitial states.** They
are visible during:

- App splash/loading screens (e.g., Bambu Studio launching)
- Mission Control (F3 / 3-finger swipe up)
- Any moment where **no foreground app is actively setting a cursor**

During normal use (Finder, browsers, text editors, etc.), macOS reasserts the
stock cursor from its own internal cache. The `CGSRegisterCursorWithImages`
call succeeds and the image is in WindowServer memory, but the system resolves
cursors through a higher-priority path during normal app focus.

**What was tried:**
- Enforcement timer that *only* re-registered — the system still won, because
  registration alone does not make a cursor *active*.
- `setDockCursorOverride` — no effect on stock resolution
- `setSystemDefinedCursor` — no effect
- Cursor scale nudge (scale-bump trick) — forces a cursor re-eval but only
  sticks briefly
- Re-registering into both named (`com.apple.coregraphics.Arrow`) and indexed
  (`com.apple.cursor.0`) slots

**What fixed it:** every enforcement tick now repeats the *whole* activation
sequence, not just the registration. Each tick re-registers the images and then
re-asserts activation via `CGSSetRegisteredCursor` + `CoreCursorSet` for every
slot the skin owns, plus `setDockCursorOverride` / `setSystemDefinedCursor` and
the scale bump. `CursorChanger.reassert()` does the same thing on demand, and
the agent calls it on click (Coverage = Standard/Continuous) as well as on app
switch.

**Remaining ideas:**
- Per-connection cursor registration — `applyToFrontmost` in the agent
  registers on the frontmost app's own `CGSConnectionID`; it needs Accessibility
  / Screen Recording permission and is exposed as a menu item.
- Investigate whether `CG` vs `CGS` functions hit different cache layers
- Can we warm or clear the internal cursor cache before the system resolves?

## Executables

This package builds **three executables** plus one library:

| Executable | Target | What it is |
|---|---|---|
| `CursorChangerAgent` | `Examples/CursorChangerAgent` | Menu-bar agent (the recommended way to use this). Lives in the status bar, applies the saved skin at login, re-asserts on app switch and on clicks, and can relaunch other apps with the skin applied. |
| `CursorChangerDemo` | `Examples/CursorChangerDemo` | SwiftUI demo app with buttons: Choose Skin Folder… / Apply / Restore System Defaults / Refresh Dock + Finder. |
| `CursorChangerCLI` | `Sources/CursorChangerCLI` | One-shot scriptable commands: `apply`, `restore`, `capture`, `debug`. Run `swift run CursorChangerCLI --help` for the full usage text. |
| `CursorChanger` | `Sources/CursorChanger` | The library every executable above links against. |

## Commands

```bash
./build.sh                  # build + run test harness
swift build
swift run TestRunner        # self-hosted assertions

# Menu-bar agent (recommended)
swift run CursorChangerAgent

# SwiftUI demo GUI: pick skin folder, Apply/Restore
swift run CursorChangerDemo

# One-shot CLI
swift run CursorChangerCLI --help
swift run CursorChangerCLI apply ~/Skins/tuff
swift run CursorChangerCLI restore
```

Quick test with the bundled Tuff Icons skin:

```bash
swift run CursorChangerDemo
# Click "Choose Skin Folder…", select Examples/Skins/Tuff, then Apply.
```

The agent auto-discovers `Examples/Skins/Tuff` relative to its own executable,
so `swift run CursorChangerAgent` works from a clean checkout with no skin
selected. Override it with the `CURSOR_CHANGER_SKIN` environment variable or the
status-bar "Choose Skin…" item.

## Skin format

A skin is a folder:

```
my-skin/
├── theme.json          optional metadata + hotspot/size overrides
├── arrow.png           required (png/svg/jpg/tiff)
├── arrow@2x.png        optional Retina rep (else 1x is upscaled)
├── ibeam.svg           any subset of states may be provided
└── ...
```

Recognized states (file stem = state name): `arrow`, `ibeam`, `pointingHand`,
`crosshair`, `openHand`, `closedHand`, `resizeLeft`, `resizeRight`, `resizeUp`,
`resizeDown`, `resizeLeftRight`, `resizeUpDown`, `move`, `operationNotAllowed`,
`dragCopy`, `dragLink`, `contextMenu`, `busyAndArrow`.

Only provided states are replaced; everything else keeps the system default.

`theme.json`:

```json
{
  "name": "My Skin",
  "hotspots": { "arrow": [4, 1] },
  "sizes":    { "arrow": 32 }
}
```

- `hotspots`: `[x, y]` in points from the image's top-left corner. Defaults
  queried from `NSCursor.hotSpot` at runtime.
- `sizes`: edge length in points (square). Defaults from the matching system
  cursor's size. Values must be between **1 and 1024 pt** — anything larger
  (including non-finite values) is rejected with an explicit error instead of
  being handed to the rasterizer, which would try to allocate a bitmap of
  `size × 2` pixels on each side.

## Library API

```swift
import CursorChanger

// A leading ~ is expanded, so the path from the README always works.
let theme = try CursorTheme.load(skinPath: "~/Skins/tuff")
let report = try CursorChanger.apply(theme: theme)   // ApplyReport with per-state results
print(report.summary)
try CursorChanger.restore()                          // back to stock cursors

// Optional: keep re-asserting the skin every 1.5s.
CursorChanger.startEnforcement(theme: theme)
CursorChanger.stopEnforcement()
```

## Architecture

| Component | Role |
|---|---|
| `CGSBridge` | dlopen/dlsym bindings to private CoreGraphics C functions |
| `CursorState` | Maps 18 cursor states to CGS names and integer slot IDs |
| `CursorTheme` | Folder loading, validation, hotspot/size resolution |
| `ThemeImageLoader` | NSImage → CGImage rasterization at 1x/2x |
| `CursorChanger` | apply/restore/reassert/enforce entry points |
| `DisplayChangeMonitor` | CGDisplayReconfigurationCallback for display change events |
| `StockCapture` | Captures stock cursor state for restore |
| `Diagnostics` | Logging and debugging utilities |

## Example skin credits

`Examples/Skins/Tuff` contains icons from Nieo's Game Icon Pack ("tuff icons"),
licensed for personal and commercial use without attribution. `ibeam.svg` is
original artwork for testing the SVG pipeline.

## License

MIT