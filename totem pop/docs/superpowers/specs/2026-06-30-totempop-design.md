# TotemPop — Design Document

**Date:** 2026-06-30
**Status:** Approved as a design — **NOT IMPLEMENTED. No `TotemPop` package exists.**

This document is a design proposal only. Nothing described below has been built:
there is no `Package.swift`, no `Sources/TotemPop/`, and no overlay code anywhere in
this repository. Treat every section as aspirational, not as a description of
current behaviour.

What *does* exist is unrelated groundwork: a standalone sensor-viewer app under
`test/` (`MotionSensorManager.swift` + `ContentView.swift`) that reads the same
BMI286 accelerometer over IOHID and plots X/Y/Z on screen. It is a debug viewer,
not the totem module — it has no overlay, no key-combination trigger, and no
animation. It can serve as the sensor-reading reference for a future
implementation, but it implements none of this spec's behaviour.

## What it is

A Swift Package (`TotemPop`) that monitors accelerometer input and configurable key combinations, then plays a Minecraft totem of undying pop animation as a full-screen transparent overlay on top of everything — including fullscreen apps and games.

It is a **module/library**, not a standalone app. Other apps import it via SPM and get auto-triggering totems with one line of code. A demo app is included in the package for testing during development.

## Architecture

```
TotemPop (Swift Package)
├── TotemPop.swift           // Main entry point — init(config:) + pop()
├── TotemOverlay.swift       // Full-screen click-through NSWindow via CGSSetWindowLevel
├── TotemPlayer.swift        // AVPlayer plays bundled MP4 video (with audio)
├── TotemTrigger.swift       // Owns background thread + CFRunLoop
│   ├── AccelerometerReader  // IOKit BMI286 HID reader
│   └── HotkeyMonitor        // Global CGEventTap for key combos
├── TotemConfig.swift        // Codable config struct
└── TotemRateLimiter.swift   // Token bucket: 5 pops per 2 seconds
```

## API Surface

```swift
let config = TotemConfig(
    sensitivity: 0.6,           // 0.0 = most sensitive, 1.0 = least
    mode: .drop,                // .drop or .hit
    keyCombos: [.cmd(.shift, .t)],
    volume: 0.8
)
let totempop = TotemPop(config: config)
// Auto-triggers on motion/keybind. Manual trigger:
totempop.pop()
```

## Components

### TotemPop (entry point)
- Singleton-like instance owned by the calling app
- `init(config:)` — starts trigger monitoring, loads overlay
- `pop()` — public method to trigger a totem manually
- `deinit` — stops monitoring, releases overlay
- Thread-safe: `pop()` can be called from any thread

### TotemOverlay
- Creates an `NSWindow` at `kCGMaximumWindowLevel` (above all windows including fullscreen apps)
- `ignoresMouseEvents = true` — clicks pass through
- Transparent background
- Houses an `AVPlayerLayer` that renders the video
- Alpha animation: fades in on trigger, fades out after video ends
- Window is allocated once, toggled visible/hidden for snappy re-triggers

### TotemPlayer
- Wraps `AVPlayer` + `AVPlayerLayer`
- Plays the bundled MP4 (3840x2160, 60fps, 2.7s, with audio)
- Video and audio play in sync via the embedded audio track
- Delegates: `playerDidFinish()` callback triggers fade-out

### TotemTrigger
- Runs on its own background thread with a `CFRunLoop`
- Manages two sub-components:

**AccelerometerReader:**
- Uses existing BMI286 code from the `test/` project
- Wakes AppleSPUHIDDriver via IORegistry properties
- Opens `AppleSPUHIDDevice` matching vendor page `0xFF00`, usage `3`
- Registers `IOHIDDeviceRegisterInputReportCallback` for 22-byte HID reports
- Parses 3x int32 XYZ values at byte offset 6
- Computes magnitude: `sqrt(x² + y² + z²)`
- Dispatches magnitude events to the main thread

**HotkeyMonitor:**
- Uses `CGEventTap` to listen for global key combinations
- Supports any modifier combo: Cmd+T, Cmd+Shift+T, Ctrl+Opt+Cmd+A, etc.
- Tap is installed on `kCGSessionEventTap` (sees events before any app)
- Enabled/disabled based on config

### TotemConfig
```swift
struct TotemConfig: Codable {
    var sensitivity: Double        // 0.0–1.0, default 0.5
    var mode: TriggerMode          // .drop or .hit, default .drop
    var keyCombos: [KeyCombo]      // default: [.cmd(.shift, .t)]
    var volume: Double             // 0.0–1.0, default 1.0
}

enum TriggerMode: String, Codable {
    case drop   // Detects drops (sharp downward spike + near-freefall)
    case hit    // Detects hits/taps (sharp impulse on any axis)
}

struct KeyCombo: Codable, Hashable {
    var modifiers: [CGEventFlags]
    var keyCode: CGKeyCode
}
```

Persistence: Saved to `UserDefaults` under suite `"com.totempop.settings"`. On init, merged with provided config — explicit config values override saved defaults.

### TotemRateLimiter
- Token bucket algorithm: 5 tokens max, refills 1 token every 400ms
- Each `pop()` costs 1 token
- If no tokens available, the trigger is ignored
- Prevents spam from sustained motion events

## Sensitivity Mapping

| Slider % | Threshold (g) | Notes |
|----------|--------------|-------|
| 0.0      | ~0.5g        | Extremely sensitive — tiny bumps trigger |
| 0.5      | ~2.0g        | Default — moderate taps |
| 1.0      | ~10.0g       | Very insensitive — only hard impacts |

Linear interpolation: `threshold = 0.5 + (sensitivity * 9.5)`

## Trigger Modes

**Drop mode:** Detects a sharp downward acceleration spike followed by near-zero magnitude (freefall). Threshold applied to the initial spike.

**Hit mode:** Detects a sharp impulse on any axis. Threshold applied to the peak magnitude of the impulse.

## Assets

- **Video:** `totem pop/6月30日 (1).mp4` — 3840x2160, H.264, 60fps, 2.7s, with stereo AAC audio
- The video file is copied into the SPM package as a resource
- `AVPlayer` handles both video and audio playback natively

## Integration for Other Apps

```swift
// In any Swift app that imports TotemPop:
import TotemPop

// One line to initialize with defaults
let totempop = TotemPop()

// Or with custom config
let totempop = TotemPop(config: TotemConfig(
    sensitivity: 0.3,
    mode: .hit,
    keyCombos: [.ctrl(.cmd, .a)],
    volume: 0.5
))

// Totems fire automatically. Manual override:
totempop.pop()
```

## Demo App

A minimal SwiftUI app bundled inside the SPM package that:
- Imports `TotemPop`
- Uses the existing BMI286 accelerometer code
- Demonstrates the module with default config
- Shows a settings UI for sensitivity, mode, and keybinds

## Build & Run

```bash
cd totem pop/
# Build the SPM package
swift build
# Run the demo
swift run TotemPopDemo
```
