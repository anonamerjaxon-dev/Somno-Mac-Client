# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**CursorFX** (package `cursor changer`) replaces the macOS system cursor with custom PNG/SVG artwork, system-wide, via private CoreGraphics (CGS) cursor registration. This is an original implementation — we studied the API surface that Mousecape and MaCursor documented, but our registration strategy, enforcement model, state mapping, and image pipeline are our own. Because the custom image *becomes* the real cursor in WindowServer, there is no overlay window and hotspot-defined click accuracy is guaranteed. SwiftPM library + demo app, macOS 13+.

## Cursor reversion — root cause and fix (Sept 2026)

Symptom: custom cursors only rendered during transitional states (app loading
screens, Mission Control); during normal use macOS reasserted the stock cursor
from its internal cache.

Root cause: the enforcement timer only **re-registered** the cursor images.
Registration puts the image in WindowServer memory, but does not make it
*active* — the activation steps (`CGSSetRegisteredCursor`, the `CoreCursorSet`
per-slot call, and the scale-bump refresh) were only performed once at apply
time, so the system's own cursor won from the next frame onward.

Fix: every enforcement tick now re-runs registration **and** re-asserts
activation. See `CursorChanger.enforce(bridge:cid:)` and
`CursorChanger.reassert()`. The agent also calls `reassert()` on app switch and
on click when Coverage is Standard/Continuous.

## Key Commands

```bash
./build.sh                        # build + run test harness
swift build
swift run TestRunner              # self-hosted assertions (NOT XCTest)
swift run CursorChangerAgent      # menu-bar agent (recommended)
swift run CursorChangerDemo       # SwiftUI GUI: pick skin folder, Apply/Restore
swift run CursorChangerCLI --help # one-shot CLI: apply / restore / capture / debug
```

## Architecture

### Private API bridge
- **`CGSBridge.swift`** — dlopen/dlsym bindings; no C interop target. Symbols looked up across CoreGraphics AND ApplicationServices (on current macOS `CoreCursorUnregisterAll` exports from ApplicationServices, the rest from CoreGraphics). Key signature:
  `CGError CGSRegisterCursorWithImages(int cid, char *cursorName, bool setGlobally, bool instantly, CGSize size, CGPoint hotspot, NSUInteger frameCount, CGFloat frameDuration, CFArray images, int *seed)`
- `CGSMainConnectionID()` returns Int32. Registration is per-login-session memory in WindowServer; reverts on logout/reboot.

### Library (`Sources/CursorChanger/`)
- **`CursorChanger.swift`** — `apply(theme:) -> ApplyReport`, `restore()`, `nudgeCursorScale()` (scale-bump trick to force cursor re-eval), and `startEnforcement(theme:interval:)/stopEnforcement()` — a main-runloop timer that, every 1.5s, re-registers **and re-asserts activation** because Dock/Finder/modal panels push stock cursors over one-shot registrations. The enforcement statics are guarded by an `NSLock`. `CGSBridge.shared` is a throwing accessor (no `try!` on any reachable path).
- **`CursorState.swift`** — 18 states mapping to CGS identifiers. Arrow → `com.apple.coregraphics.Arrow` + `com.apple.cursor.0`. `crosshair` has only a best-effort coregraphics name.
- **`CursorTheme.swift`** — folder loading/validation. Defaults: size = system cursor image size, hotspot = system cursor hotspot (queried at runtime); overrides via theme.json `hotspots`/`sizes`.
- **`ThemeImageLoader.swift`** — NSImage-based rasterization of png/svg/jpg/tiff into CGImage reps at pointSize × {1x, 2x}.
- **`DisplayChangeMonitor.swift`** — CGDisplayReconfigurationCallback wrapper.

### Executables & tests
- **`Examples/CursorChangerAgent/main.swift`** — menu-bar agent: folder picker, Apply/Restore, Coverage modes (needs Accessibility permission), relaunch-app-with-skin, per-connection "Apply Skin to Frontmost App…", Launch-at-Login. Log at `/tmp/cursor-changer-agent.log`. Skin auto-discovery walks up from `Bundle.main.executableURL`; override with `CURSOR_CHANGER_SKIN`.
- **`Examples/CursorChangerDemo/main.swift`** — SwiftUI window: folder picker, per-state status rows, Apply/Restore, auto-reapply toggle.
- **`Sources/CursorChangerCLI/main.swift`** — `apply <skin>`, `restore`, `capture`, `debug <skin>`, `--help`. `debug` always restores the stock cursors before exiting.
- **`Tests/TestRunner/main.swift`** — custom assertion harness (do NOT introduce XCTest). Covers state mapping, theme validation, SVG discovery, bridge resolution, error localization, path-traversal refusal, and off-main-thread rasterization. Each suite has independent counters, a thrown error is a failure, and temp fixtures are deleted at the end.
- **`Examples/Skins/Tuff/`** — example skin from Nieo's Game Icon Pack + original SVG ibeam.

## Important Notes
- Applying mutates the live user session; Restore or reboot clears it. Never register inside unit tests.
- Cursor sizes are clamped: 1–1024 pt, and at most 2048 px per rasterized side. Larger values throw rather than allocating.
- All AppKit rasterization goes through `CursorChangerRendering.onMainThread { }`. A caller that *blocks* the main thread while waiting for background rasterization will deadlock — pump the run loop instead.
- If hotspots render vertically mirrored, flip the pass-through in `CursorTheme.resolveHotspot`.
- After major macOS updates, re-verify identifier tables and CGS symbol availability.