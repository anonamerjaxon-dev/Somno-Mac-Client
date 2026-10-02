# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**CursorFX** (codenamed Polymorph) replaces the macOS system cursor with custom PNG/SVG artwork, system-wide, via private CoreGraphics (CGS) cursor registration. This is an original implementation — we studied the API surface that Mousecape and MaCursor documented, but our registration strategy, enforcement model, state mapping, and image pipeline are our own. Because the custom image *becomes* the real cursor in WindowServer, there is no overlay window and hotspot-defined click accuracy is guaranteed. SwiftPM library + demo app, macOS 13+.

## ⚠️ Known Issue — Cursor Reversion (Sept 2026)

Custom cursors only render during transitional states (app loading screens, Mission Control). During normal foreground app usage, macOS reasserts the stock cursor from its internal cache. The CGS registration succeeds — the image is in WindowServer memory — but the system's per-frame cursor resolution uses a higher-priority path. This is the #1 unresolved problem.

See `README.md` under "Known Issue" for the full symptom matrix, what we've tried, and brainstormed approaches for next session.

## Key Commands

```bash
./build.sh                  # build + run test harness
swift build
swift run TestRunner        # self-hosted assertions (NOT XCTest)
swift run PolymorphDemo     # GUI: pick skin folder, Apply/Restore
```

## Architecture

### Private API bridge
- **`CGSBridge.swift`** — dlopen/dlsym bindings; no C interop target. Symbols looked up across CoreGraphics AND ApplicationServices (on current macOS `CoreCursorUnregisterAll` exports from ApplicationServices, the rest from CoreGraphics). Key signature:
  `CGError CGSRegisterCursorWithImages(int cid, char *cursorName, bool setGlobally, bool instantly, CGSize size, CGPoint hotspot, NSUInteger frameCount, CGFloat frameDuration, CFArray images, int *seed)`
- `CGSMainConnectionID()` returns Int32. Registration is per-login-session memory in WindowServer; reverts on logout/reboot.

### Library (`Sources/Polymorph/`)
- **`Polymorph.swift`** — `apply(theme:) -> ApplyReport`, `restore()`, `nudgeCursorScale()` (scale-bump trick to force cursor re-eval), and `startEnforcement(theme:interval:)/stopEnforcement()` — a main-runloop timer that re-registers every 1.5s because Dock/Finder/modal panels push stock cursors over one-shot registrations.
- **`CursorState.swift`** — 18 states mapping to CGS identifiers. Arrow → `com.apple.coregraphics.Arrow` + `com.apple.cursor.0`. `crosshair` has only a best-effort coregraphics name.
- **`CursorTheme.swift`** — folder loading/validation. Defaults: size = system cursor image size, hotspot = system cursor hotspot (queried at runtime); overrides via theme.json `hotspots`/`sizes`.
- **`ThemeImageLoader.swift`** — NSImage-based rasterization of png/svg/jpg/tiff into CGImage reps at pointSize × {1x, 2x}.
- **`DisplayChangeMonitor.swift`** — CGDisplayReconfigurationCallback wrapper.

### Demo & tests
- **`Examples/PolymorphDemo/main.swift`** — SwiftUI window: folder picker, per-state status rows, Apply/Restore, auto-reapply toggle.
- **`Tests/TestRunner/main.swift`** — custom assertion harness (do NOT introduce XCTest). Covers state mapping, theme validation, SVG discovery, bridge resolution.
- **`Examples/Skins/Tuff/`** — example skin from Nieo's Game Icon Pack + original SVG ibeam.

## Important Notes
- Applying mutates the live user session; Restore or reboot clears it. Never register inside unit tests.
- If hotspots render vertically mirrored, flip the pass-through in `CursorTheme.resolveHotspot`.
- After major macOS updates, re-verify identifier tables and CGS symbol availability.