# GhostTrail

A macOS library that renders customizable fading trails behind dragged windows. Think CursorTrail — but for window movement.

Works on macOS 13+ at 60fps using hybrid `CADisplayLink`/`CVDisplayLink`, SwiftUI Canvas rendering, and `CGWindowList` polling.

## Features

- **Three render styles**: `outline` (stroke only), `filled` (translucent fill + stroke), `solid` (layered fills with density gradient)
- **Configurable fade**: frames fade out linearly over `fadeDuration`, no jitter or buffer-size dependency
- **One trail at a time**: only the window actively being dragged renders a trail; previous trails clear instantly when switching windows
- **Rounded corners**: configurable corner radius matches actual window appearance
- **Color modes**: solid, gradient, cycling rainbow
- **Glow**: optional blur-based glow per-frame
- **Window level**: render above all windows (`.aboveWindows`) or behind the dragged window (`.behindWindows`, the default)
- **Multi-display**: the overlay spans every attached screen and window frames are converted from global Quartz coordinates, so trails land correctly on secondary displays
- **Layer support**: tracks layer-0 and layer-1 windows
- **5 built-in presets**: subtle, dramatic, retro, neon, glass

## Quick Start

### Add to your project

```swift
// In Package.swift
.package(url: "…", branch: "main")
```

### Minimal usage

```swift
import GhostTrail

// Start with defaults
GhostTrail().start()

// Stop
GhostTrail.current?.stop()
```

### Builder API

```swift
GhostTrail()
    .strokeColor(.solid(.cyan))
    .strokeWidth(2)
    .frameCount(25)
    .fadeDuration(1.5)
    .opacity(0.9)
    .style(.solid)
    .glow(GlowConfig(radius: 12, intensity: 0.7, color: .cyan))
    .cornerRadius(8)
    .start()
```

### Presets

```swift
GhostTrail().preset(.subtle).start()
GhostTrail().preset(.dramatic).start()
GhostTrail().preset(.retro).start()
GhostTrail().preset(.neon).start()
GhostTrail().preset(.glass).start()
```

## Configuration Reference

| Property | Type | Default | Description |
|---|---|---|---|
| `strokeColor` | `TrailColor` | `.solid(.white)` | `.solid(Color)`, `.gradient(from, to)`, or `.rainbow` |
| `strokeWidth` | `CGFloat` | `2` | Line width for outline/filled modes (0.5–∞) |
| `frameCount` | `Int` | `20` | Max trail frames stored in ring buffer (≥10) |
| `fadeDuration` | `TimeInterval` | `1.5` | Seconds before a frame fully fades away |
| `movementThreshold` | `CGFloat` | `1` | Minimum pixel delta to register as movement |
| `jumpThreshold` | `CGFloat` | `200` | Position delta treated as a teleport; the stale trail is discarded |
| `opacity` | `Double` | `0.8` | Base opacity (0.0–1.0) |
| `style` | `TrailStyle` | `.outline` | `.outline`, `.filled`, or `.solid` |
| `glow` | `GlowConfig?` | `nil` | Optional glow radius + intensity + color |
| `cornerRadius` | `CGFloat` | `8` | Rounded corner radius in points |
| `windowLevel` | `TrailWindowLevel` | `.behindWindows` | `.behindWindows` (under the dragged window) or `.aboveWindows` |

Builder equivalents: `.strokeColor(_:)`, `.strokeWidth(_:)`, `.frameCount(_:)`, `.fadeDuration(_:)`, `.movementThreshold(_:)`, `.jumpThreshold(_:)`, `.opacity(_:)`, `.style(_:)`, `.glow(_:)`, `.cornerRadius(_:)`, `.windowLevel(_:)`, `.preset(_:)`.

### TrailColor

```swift
.solid(.cyan)              // Fixed color
.gradient(.red, .blue)     // Linear blend across frames
.rainbow                   // Cycling HSL hue
```

### GlowConfig

```swift
GlowConfig(radius: 8, intensity: 0.5, color: nil)
// radius:     blur spread in points
// intensity:  0–1
// color:      nil = uses trail color; or override
```

## Presets

| Preset | Style | Color | Frame Count | Fade | Opacity | Glow |
|---|---|---|---|---|---|---|
| `subtle` | outline | white 0.4 | 15 | 0.5s | 0.4 | — |
| `dramatic` | solid | white | 30 | 1.2s | 0.85 | radius 8, intensity 0.5 |
| `retro` | outline | green | 20 | 0.8s | 0.7 | — |
| `neon` | solid | cyan | 25 | 1.0s | 0.9 | radius 12, intensity 0.7, cyan |
| `glass` | solid | white 0.2 | 35 | 1.5s | 0.3 | radius 6, intensity 0.15, white |

## Demo

Build and run the menu-bar demo app:

```bash
cd "ghost trail"
swift build
.build/debug/GhostTrailDemo
```

A tray icon appears. Click it to start/stop trails, pick presets, or use keyboard shortcuts (1–6).

## Architecture

```
Sources/GhostTrail/
├── GhostTrail.swift              # Builder API, lifecycle, display link
├── GhostTrailConfiguration.swift # Config struct + presets
├── GhostTrailRenderer.swift      # SwiftUI Canvas trail drawing
├── GhostTrailWindow.swift        # Transparent overlay NSWindow
├── TrailColor.swift              # Color enum
├── TrailCoordinateConverter.swift # Quartz global → overlay view coordinates
├── TrailStyle.swift              # Style enum
├── TrailFrame.swift              # Per-frame data (rect + timestamp)
├── GlowConfig.swift              # Glow configuration
├── RingBuffer.swift              # Fixed-capacity O(1) buffer
└── WindowTracker.swift           # CGWindowList polling + per-window tracking
```

- **Window tracking**: `CGWindowListCopyWindowInfo` polls layer-0/1 window positions, stores history in per‑window `RingBuffer<TrailFrame>`. Polling is throttled to ~30 Hz because the call is system-wide and permission-checked; rendering still runs at display refresh rate.
- **Coordinate conversion**: `TrailCoordinateConverter` maps each window's Quartz rect (top‑left origin, +y down) into the overlay's view space by flipping about the **main** display height and subtracting the overlay origin. Flipping about the overlay height instead would misplace every trail on a secondary display.
- **Rendering**: SwiftUI `Canvas` draws directly on GPU via Metal
- **Display link**: `NSScreen.displayLink` (macOS 15+) with `CVDisplayLink` fallback (macOS 13–14); both paths report failure instead of trapping, and `start()` tears down cleanly and returns `false` when no display link can be created

## Tests

```bash
cd "ghost trail"
swift test
```

`Tests/GhostTrailTests` covers the ring buffer, configuration clamping, and the coordinate conversion (including secondary displays to the left of and above the main one).

## License

MIT