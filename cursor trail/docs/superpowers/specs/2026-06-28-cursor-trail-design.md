# Cursor Trail Module — Design Document

**Date:** 2026-06-28
**Status:** Approved
**Location:** `cursor trail/`

---

## Overview

A system-wide macOS library that renders a customizable cursor trail overlay. Any app can import it via Swift Package Manager to add cursor trail functionality. The trail replaces the system cursor and draws a smooth, animated trail behind the cursor position.

---

## Architecture

### Language & Framework
- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI + AppKit (for window management)
- **Rendering:** SwiftUI Canvas with optional Metal fallback for complex effects
- **Distribution:** Swift Package Manager (SPM)

### Module Structure

```
CursorTrail/
├── Sources/
│   ├── CursorTrail/
│   │   ├── CursorTrail.swift          # Main entry point (builder)
│   │   ├── TrailConfiguration.swift   # Configuration struct
│   │   ├── TrailRenderer.swift        # Rendering engine
│   │   ├── TrailWindow.swift          # Transparent overlay window
│   │   ├── TrailStyle.swift           # Style definitions (line, ribbon)
│   │   ├── CustomizationOptions.swift # Color, thickness, length, speed
│   │   └── Effects/
│   │       ├── GlowEffect.swift       # Optional glow
│   │       ├── ParticleEffect.swift   # Optional particles
│   │       └── BlurEffect.swift       # Optional blur
│   └── CursorTrail.h                  # Umbrella header
├── Package.swift
├── README.md
└── Examples/
    └── ExampleApp/                    # Demo app showing usage
```

---

## Core Components

### 1. CursorTrail (Main Entry Point)

The primary class developers interact with. Uses the builder pattern for configuration.

```swift
CursorTrail()
    .color(.red.gradient(to: .blue))
    .thickness(4)
    .length(150)
    .style(.line)  // or .ribbon
    .speed(.adaptive)  // trail reacts to cursor speed
    .glow(radius: 8, intensity: 0.5)  // optional
    .particles(.stars(count: 5))       // optional
    .start()
```

### 2. TrailConfiguration

A value type holding all trail settings. Can be serialized for persistence.

```swift
struct TrailConfiguration {
    var color: TrailColor         // .solid, .gradient, .rainbow
    var thickness: CGFloat        // 1–20 points
    var length: Int               // Number of trail points retained
    var style: TrailStyle         // .line, .ribbon
    var speedMode: SpeedMode      // .fixed, .adaptive
    var glow: GlowConfig?        // Optional glow
    var particles: ParticleConfig? // Optional particles
    var blur: BlurConfig?        // Optional blur
}
```

### 3. TrailRenderer

Handles the actual drawing. Uses SwiftUI `Canvas` for 60fps rendering.

- **Line style:** Smooth path connecting retained cursor positions
- **Ribbon style:** Thick bezier path with variable width based on speed
- Points are retained in a ring buffer; oldest points fade out

### 4. TrailWindow

A transparent, borderless `NSWindow` that floats above all other windows:

- `NSWindow.level = .screenSaver` — above everything
- `isOpaque = false`, `backgroundColor = .clear`
- `ignoresMouseEvents = true` — clicks pass through
- Cursor is hidden via `CGDisplayHideCursor` when active

### 5. CustomizationOptions

| Property | Type | Range | Description |
|----------|------|-------|-------------|
| `color` | `TrailColor` | — | Solid, gradient, or rainbow cycle |
| `thickness` | `CGFloat` | 1–20 | Line width in points |
| `length` | `Int` | 10–500 | Trail points retained before fade |
| `style` | `TrailStyle` | — | `.line` or `.ribbon` |
| `speedMode` | `SpeedMode` | — | `.fixed` or `.adaptive` |
| `glow` | `GlowConfig?` | — | Glow radius and intensity |
| `particles` | `ParticleConfig?` | — | Shape, count, lifetime |
| `blur` | `BlurConfig?` | — | Blur radius |

---

## Performance Requirements

- **60fps minimum** — all rendering must hit 60fps on modern Macs
- **Minimal footprint** for simple trails (line/ribbon only)
- **Optional effects** (glow, particles, blur) can be enabled independently
- Trail point buffer uses ring buffer for O(1) append/evict
- SwiftUI Canvas renders on GPU via Metal automatically

---

## API Design

### Builder Pattern (Primary API)

```swift
// Minimal
CursorTrail().color(.cyan).start()

// Full configuration
CursorTrail()
    .color(.gradient(.red, .blue))
    .thickness(6)
    .length(200)
    .style(.ribbon)
    .speed(.adaptive)
    .glow(GlowConfig(radius: 10, intensity: 0.6))
    .particles(ParticleConfig(shape: .star, count: 8, lifetime: 1.5))
    .start()

// Stop
CursorTrail.current?.stop()
```

### SwiftUI Modifier (Convenience)

```swift
import SwiftUI

Window("My App")
    .cursorTrail { trail in
        trail.color(.rainbow).thickness(3)
    }
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Accessibility permissions denied | Graceful fallback with clear error message |
| Screen recording denied | Graceful fallback with clear message |
| Multiple instances | Only one trail active; second `start()` returns false |
| Memory pressure | Automatically reduce trail length |

---

## Security & Permissions

- **Accessibility:** Required to hide system cursor (`AXIsProcessTrusted`)
- **Screen Recording:** Required to draw overlay on screen
- Library checks permissions on `start()` and provides clear user guidance

---

## Testing

- Unit tests for configuration, ring buffer, trail math
- Performance tests confirming 60fps with max settings
- Integration tests with example app
- Permission denial tests

---

## Future Considerations

- Metal shader support for advanced effects
- iOS/iPadOS support via cross-platform abstraction
- Animated trail textures (fire, magic, etc.)
- Multiple cursor support (trackpad + mouse simultaneously)
