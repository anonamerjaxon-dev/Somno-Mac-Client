# Somno Mac Client

A macOS UI enhancement toolkit inspired by Minecraft hack-client aesthetics. Built as a learning project — each module adds a distinct visual layer to the macOS experience.

> **Before changing anything:** [AGENTS.md](AGENTS.md) is the canonical source for module identities (including what is and isn't a module), repo conventions, and audit history. Read it first.

## Modules

### CursorTrail

A Swift library that draws a smooth, animated trail behind the mouse cursor. Renders on a transparent overlay at `.screenSaver` window level — floating above everything while passing clicks through.

```swift
import CursorTrail
CursorTrail()
    .color(.gradient(.cyan, .purple))
    .style(.ribbon)
    .start()
```

→ [cursor trail/README.md](cursor%20trail/README.md) for full API and presets.

### Cursor Changer *(formerly Polymorph / CursorFX)*

System-wide custom cursor replacement using WindowServer-level cursor registration. Replaces the stock macOS arrow, ibeam, pointing hand, and more with custom PNG/SVG artwork. Registers images directly into the CoreGraphics cursor registry so custom cursors render natively — no overlay window, no input latency.

This is an **original implementation** built by reverse-engineering the private CGS cursor API surface (the same class of APIs that Mousecape and MaCursor discovered). The approach — registration strategy, enforcement model, state mapping, and image pipeline — are our own.

```swift
import CursorChanger
let theme = try CursorTheme.load(directory: skinFolder)
try CursorChanger.apply(theme: theme)
```

→ [cursor changer/README.md](cursor%20changer/README.md) for skin format, commands, and library API.

> `cursor changer/` (formerly `polymorph/`, CursorFX) is the user's personal cursor tool — always call it **cursor changer**. The SwiftPM package, library type, and targets match the new name (`CursorChanger`, `CursorChangerAgent`, `CursorChangerCLI`, `CursorChangerDemo`). See [AGENTS.md](AGENTS.md).

> **⚠️ Known issue (Sept 2026):** Custom cursors currently only render during transitional states — app splash/loading screens, Mission Control animations, etc. During normal foreground app usage, macOS reasserts the stock cursor. The registration succeeds but the system has a higher-priority cursor path we haven't intercepted yet. This is the #1 item to solve next session.

### Desktop Canvas

Desktop wallpaper and procedural art module — renders animated content *behind* the desktop icons with native performance and zero input interference. Video canvases (MP4/MOV via AVPlayer, aspect-locked) and GPU-accelerated Game of Life canvases (Metal compute), placed freely per display and persistent across Spaces and Mission Control.

→ [desktop-canvas/README.md](desktop-canvas/README.md) for architecture, presets, and the editor UI.

### Ghost Trail

Renders a customizable fading trail behind a window while you drag it — think CursorTrail, but for window movement. Three render styles, solid/gradient/rainbow color modes, optional glow, and five built-in presets.

→ [ghost trail/README.md](ghost%20trail/README.md) for the builder API and presets.

### Black Hole (Ghostty) — *reference material*

> **Reference-only:** `black hole/` is vendored material the user kept for reference (Ghostty shader + tuner). It is **not a module to recreate, extend, or fix** — see [AGENTS.md](AGENTS.md).

A GLSL custom shader for the [Ghostty](https://ghostty.org) terminal that renders a physically-accurate Schwarzschild black hole with gravitational lensing, a thin accretion disk, photon ring, and lensed starfield. Integrates null geodesics numerically per pixel.

Three size modes: Pomodoro clock, live Claude Code context-window tracking (via OSC 12 cursor color encoding), and a self-running demo loop.

→ [black hole/ghostty-blackhole-main/README.md](black%20hole/ghostty-blackhole-main/README.md)

### Totem Pop *(in development)*

Reads the Bosch BMI286 IMU accelerometer from Apple Silicon Macs via IOHID to detect sudden motion (desk slap, laptop bump). When triggered, a totem animation will play on screen.

```bash
cd totem\ pop/test
./build.sh
sudo ./build/MotionSensor
```

→ [totem pop/CLAUDE.md](totem%20pop/CLAUDE.md) for hardware requirements and architecture.

## Planned

| Module | Status |
|---|---|
| **HUD** | Planned — heads-up display overlay; the core system all modules plug into |
| **Client** | Planned — central module manager: toggles, config, and coordination |
| **Music Display** | Planned — real-time audio visualizer from system audio output |
| **Moving Wallpaper** | ✅ Shipped as `desktop-canvas/` video canvases (MP4/MOV as desktop background) |
| **Fun Wallpapers** | ✅ Shipped as `desktop-canvas/` Game of Life / cellular automata canvases |
| **Window Drag Trail** | ✅ Shipped as `ghost trail/` |

## Project Structure

```
somno mac client/
├── AGENTS.md          module identities + project conventions (read first)
├── cursor trail/      SwiftPM library — mouse trail rendering
├── cursor changer/    SwiftPM library — custom cursor replacement (formerly polymorph/)
├── desktop-canvas/    SwiftPM package — video / Game of Life desktop wallpapers
├── ghost trail/       SwiftPM library — trails behind dragged windows
├── totem pop/         SwiftUI app — motion sensor viewer (test/) + design docs
├── black hole/        Ghostty terminal shader — REFERENCE ONLY (see AGENTS.md)
├── LICENSE            MIT
└── README.md          ← you are here
```

Each module has its own `Package.swift` (or equivalent) and documentation. Test coverage varies by module: `cursor trail/`, `desktop-canvas/`, and `ghost trail/` have real test suites; `cursor changer/` ships a runnable `TestRunner` harness; `totem pop/` has a self-test harness under `test/`; `black hole/` (reference-only) has none. The modules are independent but designed to eventually plug into a shared HUD/Client system.

## Development

```bash
# CursorTrail
cd cursor\ trail && swift build && swift test

# Cursor Changer (formerly polymorph/)
cd cursor\ changer && ./build.sh

# Desktop Canvas
cd desktop-canvas && swift build && swift test

# Ghost Trail
cd ghost\ trail && swift build && swift test

# Totem Pop
cd totem\ pop/test && ./build.sh
```

## Architecture Notes

- **CursorTrail** renders via a transparent `NSWindow` at `.screenSaver` level with `ignoresMouseEvents = true`. Rendering is synced to display refresh via `CVDisplayLink`.
- **Cursor Changer** uses `CGSRegisterCursorWithImages` (private CoreGraphics) to register custom images into WindowServer's cursor cache. The enforcement timer re-registers on a loop to fight the system's tendency to reassert stock cursors.
- **Desktop Canvas** hosts provider views (Metal-compute Game of Life, AVPlayer video) in borderless windows at desktop-icon window level, ordered below Finder's icons so clicks pass through to the desktop.
- **Ghost Trail** polls `CGWindowList` for the window being dragged and paints a fading overlay synced to the display link.
- **Black Hole** is a single `.glsl` shader file. No custom uniforms — context data is encoded into the cursor color (OSC 12) and decoded by the shader each frame.
- **Totem Pop** uses `IOHIDDeviceOpen` (requires `sudo`) to read raw accelerometer data from the BMI286 chip via `AppleSPUHIDDevice`.

## License

MIT
