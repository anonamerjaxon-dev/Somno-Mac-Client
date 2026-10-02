# CursorChanger — Custom Cursor Replacement Module

**Date:** 2026-08-24
**Status:** Approved design, pending implementation plan
**Module:** `cursor changer/` (Somno Mac Client). Renamed from `polymorph/` — targets and types are `CursorChanger*`.

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
cursor changer/
├── CLAUDE.md, README.md, Package.swift, build.sh
├── Sources/
│   ├── CursorChanger/             — Swift library target
│   │   ├── CursorChanger.swift    — entry: apply(theme:) -> ApplyReport, restore()
│   │   ├── CursorTheme.swift      — folder loading, validation, model
│   │   ├── CursorState.swift      — enum of states: file stems + CGS names/aliases
│   │   └── ThemeImageLoader.swift — SVG/PNG → CGImage at 1x/2x
│   (CGSBridge.swift uses dlopen/dlsym instead of a C interop target;
│    symbols resolve across CoreGraphics AND ApplicationServices —
│    CoreCursorUnregisterAll exports from ApplicationServices)
├── Examples/CursorChangerAgent/main.swift
│       Menu-bar (NSStatusItem) agent: choose skin folder, Apply, Restore,
│       per-state status, error log, coverage modes, auto-reapply-on-display-
│       change, per-connection "apply to frontmost app" action
├── Examples/CursorChangerDemo/main.swift
│       SwiftUI demo app (WindowGroup + buttons). It is a single file; the
│       "DemoUI.swift" named in the original draft was never created.
├── Sources/CursorChangerCLI/main.swift
│       One-shot CLI: apply / restore / capture / debug (+ --help)
└── Tests/TestRunner/main.swift    — custom assertion harness (repo style, NOT XCTest)
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
  editing the image).
  CORRECTION (2026-09): the library does **not** convert to CGS coordinate
  order. The hotspot is passed through to `CGSRegisterCursorWithImages`
  unchanged, because the CGS API takes its hotspot in the same top-left-origin
  point space.
- Default hotspot per state = `hotSpot` of the corresponding built-in
  `NSCursor` instance, queried at runtime (authoritative, never hardcoded).
  States without an NSCursor equivalent default to the image center.
- `sizes`: square edge length in points per state; defaults come from the
  matching system cursor's image size. Values must be finite and between 1 and
  1024 pt (`CursorTheme.maximumCursorPointSize`); larger values are a hard
  error, because the rasterizer allocates `size × 2` pixels per side.
- Validation errors (surface in demo UI): missing `arrow.*`, unknown key in
  `hotspots` or `sizes`, size out of range, unreadable/corrupt image, and a
  rasterized bitmap whose edge exceeds 2048 px.
  CORRECTION (2026-09): the original draft promised a warning when a supplied
  `@2x` image is not exactly 2× the 1x image. That warning was never
  implemented and is not present today.

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
entries; CursorChanger registers both per state. Live smoke test on this machine:
all 24 registrations returned success.

## Apply / restore flow

1. `CursorChanger.apply(theme:)`: load folder → validate → for each state:
   rasterize SVG/PNG to 1x (+2x) `CGImage`s → register via CGS with hotspot
   (custom override or NSCursor-derived default), frameCount 1 → collect result.
   Returns `ApplyReport` (per-state success/error) shown in demo UI.
2. `CursorChanger.restore()`: `CoreCursorUnregisterAll(CGSMainConnectionID())`.
3. While the demo app runs: `CGDisplayRegisterReconfigurationCallback`
   triggers re-apply + cursor-scale nudge (`CGSSetCursorScale(s+ε)` then
   restore) — Mousecape's refresh trick. Registration persists until
   logout/reboot even if the app quits.

## Error handling

- Every CGS call is checked against `kCGErrorSuccess`; failures are reported
  per-state, apply continues with the remaining states, and each failing call
  is logged through `CursorChanger.diagnosticLogger`.
  CORRECTION (2026-09): the original draft claimed this unconditionally, but
  many call sites discarded the `CGError` with `_ =`. Those discards are gone;
  the values are now captured and logged.
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

- `cursor changer/README.md` — usage, skin format spec, example skin, limitations.
- `cursor changer/CLAUDE.md` — commands, architecture, private-API cautions.
- Root `README.md` — move CursorChanger from Planned to Existing.