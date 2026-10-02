# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**CursorTrail** is a Swift library that draws a smooth, animated trail behind the mouse cursor on macOS. It renders on a transparent overlay window at `.screenSaver` window level, floating above all content. The library uses a builder pattern for configuration and targets macOS 13.0+.

## Key Commands

```bash
swift build
swift test
swift test --disable-xctest   # clean output without the XCTest bridge line
swift run TestRunner
swift run CursorTrailDemo
```

## Architecture

### Core Entry Point
- **`CursorTrail.swift`** — Main class with builder pattern (`color()`, `thickness()`, `style()`, `speed()`, etc.). Creates the overlay window, runs a CVDisplayLink render loop synced to display refresh, polls `NSEvent.mouseLocation`, appends points to a ring buffer, fades the trail when idle, and updates the window each frame. Static `current` singleton.

### Window & Rendering
- **`TrailWindow.swift`** — Transparent, borderless `NSWindow` at `.screenSaver` level with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, and `.ignoresMouseEvents = true` (clicks pass through). Hosts a SwiftUI `Canvas` in an `NSHostingView`.
- **`TrailRenderer.swift`** — Draws the trail into a `GraphicsContext`. Supports `.line` (multi-pass stroked polyline) and `.ribbon` (filled Catmull-Rom spline with perpendicular normals). Handles glow via `.blur` filter, color gradients, and rainbow HSL cycling.

### Data Structures
- **`RingBuffer.swift`** — Fixed-capacity circular buffer. O(1) append/removeFirst.
- **`TrailPoint.swift`** — `position: CGPoint`, `timestamp: CFTimeInterval`, `velocity: CGFloat`.
- **`SpeedMode.swift`** — `.fixed` or `.adaptive` (width scales with mouse velocity).

### Configuration
- **`TrailConfiguration.swift`** — All tunable parameters in one `Sendable` struct: color, thickness, length, fade speed, rainbow speed, diminishing, speed mode, opacity, glow.
- **`TrailColor.swift`** — `.solid(Color)`, `.gradient(Color, Color)`, `.rainbow`.
- **`TrailStyle.swift`** — `.line` (multi-pass stroked) or `.ribbon` (filled spline).
- **`GlowConfig.swift`** — Optional glow: radius, intensity (0-1), optional custom color.

### Demo & Testing
- **`Examples/CursorTrailDemo/main.swift`** — SwiftUI app with live controls for all parameters.
- **`Tests/CursorTrailTests/`** — **swift-testing** (`import Testing`, `@Test`/`@Suite`/`#expect`),
  NOT XCTest and not a custom harness. `swift test` runs these directly: the real executed count is
  the swift-testing `Test run with N tests` line. The `Executed 0 tests` line above it comes from the
  always-present XCTest bridge finding no XCTest cases, and is expected — ignore it.
  Run `swift test --disable-xctest` for a clean, XCTest-free line.
  Suites: `CursorTrail lifecycle` (real `CursorTrail`, `@MainActor`), `Multi-display coordinate flip`
  (pure math), `Idle fade math` (pure math), `RingBuffer`, `TrailConfiguration`,
  `TrailRenderer geometry guards`.
- **`Tests/TestRunner/main.swift`** — separate module-load smoke check (`swift run TestRunner`).
  It does not run the `CursorTrailTests` suite.

## Important Notes
- **Tests use swift-testing, not XCTest.** Do not add XCTest-based tests.
- **Lifecycle tests touching `start()`/`stop()` must be `@MainActor`.** Those methods carry
  `dispatchPrecondition(condition: .onQueue(.main))`; non-main swift-testing tests run on the
  swift concurrency pool and would trip the precondition. AppKit windows and `NSEvent.mouseLocation`
  do work inside a `swift test` process, so real windows can be created.
- `start()`/`stop()` are main-thread-only; a new instance's `start()` stops the previous trail
  (single active trail); `stop()` clears `CursorTrail.current` only when `current === self`;
  `current` is `weak`, so dropping your last reference stops the trail instead of leaking a zombie overlay.
- Coordinates are converted per-screen by `CursorTrail.localPoint(fromGlobal:screenFrame:)`:
  `x -= screenFrame.origin.x`, `y = screenFrame.maxY - y`, using the **overlay window's** screen.
  Do not reintroduce `NSScreen.main!.frame.height`-only math — it misplaces the trail on secondary displays.
- The display-link callback carries an **unretained** `DisplayLinkContext` that holds the trail
  **weakly** and serialises `withTrail` against `markReleased()`. Never make the trail strongly
  self-retaining (`Unmanaged.passRetained(self)` was the original zombie-overlay bug), and never
  release the context without first calling `markReleased()`.
- Mouse movement detection uses 0.5px squared-distance threshold to avoid jitter.
- Rainbow mode uses HSL hue rotation in `TrailRenderer.colorForTrail()`.
- Particles were removed in v0.2.0 due to instability. Do not reintroduce without thorough testing.