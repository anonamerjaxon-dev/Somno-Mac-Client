# Polymorph — Custom Cursor Replacement Module

**Date:** 2026-08-24
**Status:** Approved design, pending implementation plan
**Module:** `polymorph/` (Somno Mac Client)

## Problem

Replace the macOS system cursor with custom artwork (PNG/SVG) across all apps, with:

- A pixel-exact click point (hotspot) that stays correct everywhere.
- No overlay windows, so none of the z-order problems of the first attempt
  (the hardware cursor always renders above every window level).
- Hotspot customization per cursor state.

## Chosen technique

Private CoreGraphics (CGS) cursor registration, proven by three existing open
source projects researched on GitHub:

| Project | What we take from it |
|---|---|
| [alexzielenski/Mousecape](https://github.com/alexzielenski/Mousecape) | Original reverse-engineered API usage (GPL — study architecture only, write our own code) |
| [RainYangty/Mousecape-swiftUI](https://github.com/RainYangty/Mousecape-swiftUI) | Modern ARCHITECTURE.md documenting every API detail incl. macOS 26 behavior |
| [writronic/MaCursor](https://github.com/writronic/MaCursor) | Full cursor-state identifier list, hotspot editor UX reference |

`CGSRegisterCursorWithImages(cid, name, setGlobally: true, instantly: true, size,
hotspot, frameCount: 1, frameDuration: 0, images, &seed)` swaps the image inside
WindowServer itself. Consequences:

- The custom image *becomes* the real cursor — hit-testing cannot desync;
  clicks land exactly where the OS thinks the pointer is.
- Works in every app, above everything, zero latency, no permissions needed.
- No SIP interaction, nothing written to disk outside our own folders,
  non-persistent: reverts on logout/reboot.
- Private API risk accepted: worst case is a wrong-looking cursor until Restore
  or reboot; may need identifier updates after major macOS releases.

## Non-goals for v0.1

- Animated cursors (sprite sheets ≤24 frames) — designed-for, added later.
- LaunchAgent/login-item persistence — demo app reapplies on launch.
- Windows `.cur`/`.ani` import.
- Theme marketplace/gallery UI.

## Architecture

SwiftPM package, mirroring the CursorTrail module layout:

```
polymorph/
├── CLAUDE.md, README.md, Package.swift, build.sh
├── Sources/
│   ├── Polymorph/                 — Swift library target
│   │   ├── Polymorph.swift        — entry: apply(theme:) -> ApplyReport, restore()
│   │   ├── CursorTheme.swift      — folder loading, validation, model
│   │   ├── CursorState.swift      — enum of states: file stems + CGS names/aliases
│   │   └── ThemeImageLoader.swift — SVG/PNG → CGImage at 1x/2x
│   (CGSBridge.swift uses dlopen/dlsym instead of a C interop target;
│    symbols resolve across CoreGraphics AND ApplicationServices —
│    CoreCursorUnregisterAll exports from ApplicationServices)
├── Examples/PolymorphDemo/main.swift + DemoUI.swift
│       SwiftUI menu-bar-style app: choose skin folder, Apply, Restore,
│       per-state status list, error log, auto-reapply-on-display-change toggle
└── Tests/PolymorphTests/          — custom assertion harness (repo style, NOT XCTest)
```

## Skin format

A skin is a folder. Example `my-skin/`:

```
my-skin/
├── theme.json
├── arrow.png          (required — 1x raster or SVG)
├── arrow@2x.png       (optional — Retina rep; if absent, library upscales 1x)
├── ibeam.svg          (SVG accepted anywhere PNG is)
├── pointingHand.png
└── ...
```

`theme.json`:

```json
{
  "name": "My Skin",
  "author": "optional",
  "hotspots": { "ibeam": [8, 14], "crosshair": [16, 16] }
}
```

Rules:

- Only states with a present image get replaced; all other states keep the
  system default. `arrow` is the only *required* image (a skin replacing
  nothing would be pointless).
- Hotspot values are `[x, y]` in points, **top-left origin** (what you see when
  editing the image). Library converts to CGS coordinate order internally.
- Default hotspot per state = `hotSpot` of the corresponding built-in
  `NSCursor` instance, queried at runtime (authoritative, never hardcoded).
  States without an NSCursor equivalent default to the image center.
- `sizes`: square edge length in points per state; defaults come from the
  matching system cursor's image size, else capped at 32pt.
- Validation errors (surface in demo UI): missing `arrow.*`, unknown key in
  `hotspots`, unreadable/corrupt image. Warning only: 2x size ≠ 2× 1x size.

## Cursor states (v0.1 full set, static)

File stem → CGS registered name(s); aliases registered together:

| Stem | CGS name(s) |
|---|---|
| arrow | coregraphics.Arrow, cursor.0 |
| ibeam | coregraphics.IBeam, .IBeamXOR, cursor.1 |
| pointingHand | coregraphics.PointingHand, cursor.13 |
| crosshair | coregraphics.Crosshair (best effort) |
| openHand / closedHand | ...OpenHand/.ClosedHand + cursor.12/11 |
| resizeLeft/Right/Up/Down | ...Resize* + cursor.17/18/21/22 |
| resizeLeftRight / resizeUpDown | ...Resize*Pair + cursor.19/23 |
| move | coregraphics.Move, cursor.39 |
| operationNotAllowed | coregraphics.NotAllowed, cursor.3 |
| dragCopy | coregraphics.Copy, cursor.5 |
| dragLink | coregraphics.Alias, cursor.2 |
| contextMenu | coregraphics.ArrowCtx, cursor.24 |
| busyAndArrow | coregraphics.Wait, cursor.4 |

Verified against MaCursor's MACCursorDefs.m tables: modern macOS exposes both
named (`com.apple.coregraphics.*`) and indexed (`com.apple.cursor.N`) registry
entries; Polymorph registers both per state. Live smoke test on this machine:
all 24 registrations returned success.

## Apply / restore flow

1. `Polymorph.apply(theme:)`: load folder → validate → for each state:
   rasterize SVG/PNG to 1x (+2x) `CGImage`s → register via CGS with hotspot
   (custom override or NSCursor-derived default), frameCount 1 → collect result.
   Returns `ApplyReport` (per-state success/error) shown in demo UI.
2. `Polymorph.restore()`: `CoreCursorUnregisterAll(CGSMainConnectionID())`.
3. While the demo app runs: `CGDisplayRegisterReconfigurationCallback`
   triggers re-apply + cursor-scale nudge (`CGSSetCursorScale(s+ε)` then
   restore) — Mousecape's refresh trick. Registration persists until
   logout/reboot even if the app quits.

## Error handling

- Every CGS call checked against `kCGErrorSuccess`; failures reported
  per-state, apply continues with remaining states.
- Restore is always available; reboot clears everything (no persistence risk).
- Unknown macOS versions: if a name fails to register, report which; do not
  crash. A future settings pane could map custom names, out of scope v0.1.

## Testing

- Unit tests (custom harness like CursorTrailTests): folder discovery, JSON
  parsing, validation matrix, hotspot override/fallback resolution, 1x/2x
  scaling math, state→CGS-name mapping incl. alias pairs.
- Manual verification checklist via demo app (live WindowServer calls can't be
  unit tested): apply → verify arrow/ibeam/hand in Safari/Xcode/Finder, hover
  link → pointingHand, select text → ibeam, drag window → closedHand, click
  accuracy at hotspot corners, Restore returns stock cursors, display
  hot-plug keeps skin.

## Documentation deliverables

- `polymorph/README.md` — usage, skin format spec, example skin, limitations.
- `polymorph/CLAUDE.md` — commands, architecture, private-API cautions.
- Root `README.md` — move Polymorph from Planned to Existing.