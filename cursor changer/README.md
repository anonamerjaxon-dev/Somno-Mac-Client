# CursorFX (Polymorph)

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

**What we've tried:**
- Enforcement timer (re-register every 1.5s) — the system wins every frame
- `setDockCursorOverride` — no effect on stock resolution
- `setSystemDefinedCursor` — no effect
- Cursor scale nudge (scale-bump trick) — forces a cursor re-eval but only
  sticks briefly
- Re-registering into both named (`com.apple.coregraphics.Arrow`) and indexed
  (`com.apple.cursor.0`) slots

**Ideas for next session:**
- Per-connection cursor registration (not just global) — `CGSConnectionID`
  level instead of main connection
- Accessibility API / event tap to detect cursor changes and immediately
  re-register
- Explore integer-slot `CGSSetCoreCursor` path (slots 0-43)
- Investigate whether `CG` vs `CGS` functions hit different cache layers
- Can we warm or clear the internal cursor cache before the system resolves?

> This is the #1 priority for the next work session. Everything else in the
> module (image loading, state mapping, skin format, CGS bridge) works
> correctly.

## Commands

```bash
./build.sh                  # build + run test harness
swift build
swift run TestRunner        # self-hosted assertions
swift run PolymorphDemo     # GUI: pick skin folder, Apply/Restore
```

Quick test with the bundled Tuff Icons skin:

```bash
swift run PolymorphDemo
# Click "Choose Skin Folder…", select Examples/Skins/Tuff, then Apply.
```

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
  cursor's size.

## Library API

```swift
import Polymorph

let theme = try CursorTheme.load(directory: URL(fileURLWithPath: "~/Skins/tuff"))
let report = try Polymorph.apply(theme: theme)   // ApplyReport with per-state results
print(report.summary)
try Polymorph.restore()                          // back to stock cursors

// Optional: keep re-asserting the skin every 1.5s (known issue — see above)
Polymorph.startEnforcement(theme: theme)
Polymorph.stopEnforcement()
```

## Architecture

| Component | Role |
|---|---|
| `CGSBridge` | dlopen/dlsym bindings to private CoreGraphics C functions |
| `CursorState` | Maps 18 cursor states to CGS names and integer slot IDs |
| `CursorTheme` | Folder loading, validation, hotspot/size resolution |
| `ThemeImageLoader` | NSImage → CGImage rasterization at 1x/2x |
| `Polymorph` | apply/restore/reassert/enforce entry points |
| `DisplayChangeMonitor` | CGDisplayReconfigurationCallback for display change events |
| `StockCapture` | Captures stock cursor state for restore |
| `Diagnostics` | Logging and debugging utilities |

## Example skin credits

`Examples/Skins/Tuff` contains icons from Nieo's Game Icon Pack ("tuff icons"),
licensed for personal and commercial use without attribution. `ibeam.svg` is
original artwork for testing the SVG pipeline.

## License

MIT