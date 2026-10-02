# CursorTrail

A lightweight Swift library that draws a smooth, animated trail behind the mouse cursor on macOS. Renders on a transparent overlay window at `.screenSaver` level — floating above all content while passing clicks through.

<p align="center">
  <img src="demo.gif" alt="CursorTrail demo" width="600"/>
</p>

## Requirements

- macOS 13.0+
- Swift 5.9+

## Quick Start

```swift
import CursorTrail

// Start with defaults (rainbow ribbon)
CursorTrail().start()

// Stop it
CursorTrail.current?.stop()
```

## Configuration

Use the builder pattern — chain config calls, then `.start()`:

```swift
CursorTrail()
    .color(.gradient(.cyan, .purple))
    .thickness(14)
    .length(80)
    .style(.ribbon)
    .fadeSpeed(1.0)
    .rainbowSpeed(5.0)
    .diminishing(true)
    .diminishingIntensity(0.7)
    .opacity(0.8)
    .glow(GlowConfig(radius: 8, intensity: 0.5))
    .start()
```

## Defaults

| Parameter | Default | Description |
|---|---|---|
| `color` | `.rainbow` | Cycling HSL spectrum |
| `style` | `.ribbon` | Filled Catmull-Rom spline |
| `thickness` | `12` | Trail width in points |
| `length` | `10` | Max trail points in buffer |
| `fadeSpeed` | `1.0` | Points removed per frame when idle |
| `rainbowSpeed` | `5.0` | Multiplier for hue cycle speed |
| `diminishing` | `true` | Tail tapers thinner toward the head |
| `diminishingIntensity` | `0.7` | 0 = uniform, 1 = max taper |
| `opacity` | `0.8` | Overall transparency (0.0–1.0) |
| `speed` | `.adaptive` | Width scales with mouse velocity |
| `glow` | `nil` | Optional glow behind the trail |

## API Reference

### `TrailColor`

```swift
public enum TrailColor {
    case solid(Color)              // e.g. .solid(.cyan)
    case gradient(Color, Color)    // e.g. .gradient(.red, .blue)
    case rainbow                   // HSL hue cycling
}
```

### `TrailStyle`

```swift
public enum TrailStyle {
    case line     // Multi-pass stroked polyline (4 passes for depth)
    case ribbon   // Filled Catmull-Rom spline with perpendicular normals
}
```

### `SpeedMode`

```swift
public enum SpeedMode {
    case fixed     // Constant width regardless of speed
    case adaptive  // Width scales with mouse velocity
}
```

### `GlowConfig`

```swift
GlowConfig(radius: 8, intensity: 0.5, color: nil)
// radius:    blur spread in points
// intensity: 0.0 (invisible) to 1.0 (full)
// color:     nil uses the trail's current color, or specify a custom one
```

## Recommended Presets

### Subtle

```swift
CursorTrail()
    .color(.solid(.gray))
    .thickness(4)
    .length(50)
    .style(.line)
    .diminishing(true)
    .diminishingIntensity(0.3)
    .opacity(0.5)
    .start()
```

### Bold

```swift
CursorTrail()
    .color(.gradient(.cyan, .magenta))
    .thickness(20)
    .length(150)
    .style(.ribbon)
    .diminishing(false)
    .glow(GlowConfig(radius: 15, intensity: 0.7))
    .opacity(0.9)
    .start()
```

### Minimal

```swift
CursorTrail()
    .color(.solid(.white))
    .thickness(2)
    .length(20)
    .style(.line)
    .diminishing(true)
    .diminishingIntensity(0.5)
    .opacity(0.6)
    .start()
```

## Architecture

| Component | Role |
|---|---|
| `CursorTrail` | Main class — builder API, CVDisplayLink render loop, mouse tracking |
| `TrailConfiguration` | All tunable parameters in one `Sendable` struct |
| `TrailWindow` | Transparent `NSWindow` at `.screenSaver` level, ignores mouse events |
| `TrailModel` | `ObservableObject` holding `@Published` trail points |
| `TrailContentView` | SwiftUI `Canvas` view that delegates to `TrailRenderer` |
| `TrailRenderer` | Draws line/ribbon/glow into `GraphicsContext` |
| `RingBuffer` | Fixed-capacity circular buffer for O(1) point storage |
| `TrailPoint` | Data model: position, timestamp, velocity |

The window uses `.ignoresMouseEvents = true` so clicks pass through. `.canJoinAllSpaces` + `.fullScreenAuxiliary` ensures visibility across all Spaces and full-screen apps. Rendering is synced to the display refresh rate via `CVDisplayLink`.

## Demo App

The included demo (`CursorTrailDemo`) provides a polished UI for live-tuning all parameters:

```bash
swift run CursorTrailDemo
```

## Important Notes

- `start()` and `stop()` must be called on the **main thread** — they assert it, since they
  create and tear down `NSWindow` and `CVDisplayLink` objects.
- Calling `.start()` on a new instance automatically stops any previously running trail —
  there is only ever one active trail. Calling `.start()` twice on the *same* instance is a
  no-op that returns `false`.
- The overlay is anchored to the display under the cursor when `start()` runs (main display
  otherwise). It does not follow the cursor to another display while running; move the cursor
  across screens and restart the trail to re-anchor it.
- **Don't reuse the builder** after `.start()`. The builder pattern snapshots configuration at start time.
- **Don't set `opacity` to 0** — the trail won't be visible. Opacity is 0.0–1.0, not a percentage.
- **Don't expect it to work in full-screen games** — apps using `CGDisplayCapture` block overlay drawing.
- **Don't mix `.solid` color with `.rainbowSpeed`** — rainbow speed only affects `.rainbow` color mode.
- Always call `.stop()` if you hold a strong reference. If you drop your last reference while
  running, the trail stops itself (`CursorTrail.current` is a weak reference, so it does not
  keep the trail alive).

## License

MIT