# Phase 5: Desktop Window & Screen Manager — Agent Prompt

## Your task

Implement the windowing system that puts canvases on the macOS desktop.
Three files. After Phase 5, you can run `DesktopCanvas.shared.apply(layout:)` and
see Game of Life + video canvases rendering behind your desktop icons on all screens.

After done: `swift build` must pass with zero errors, zero warnings.

---

## Project context

**Repo root:** `./`
**Module:** `desktop-canvas/`
**What:** DesktopCanvas renders dynamic content behind macOS desktop icons.

### What already exists (Phases 0–4 done, builds clean)

```
desktop-canvas/
├── Package.swift
├── Sources/
│   └── DesktopCanvas/
│       ├── CodableColor.swift         ← Phase 1
│       ├── CanvasLayout.swift         ← Phase 1
│       ├── Canvas.swift               ← Phase 1
│       ├── RuleSet.swift              ← Phase 1
│       ├── CanvasProvider.swift       ← Phase 2 (protocol)
│       ├── CanvasRenderer.swift       ← Phase 2 (NSView wrapper, clips to bounds)
│       ├── GameOfLifeProvider.swift   ← Phase 3 (MTKView + Metal compute)
│       └── VideoProvider.swift        ← Phase 4 (AVPlayer + AVPlayerLayer)
```

### Key types you'll use (read-only — do NOT modify these files)

- `CanvasProvider` protocol: `var canvas: Canvas`, `attach(to:frame:)`, `detach()`, `update()`, `pause()`, `resume()`
  - `GameOfLifeProvider` implements this (subclasses MTKView, Metal compute kernel)
  - `VideoProvider` implements this (AVPlayer + AVPlayerLayer)
- `CanvasRenderer` (NSView): wraps a provider, clips to bounds, routes resize/attach/detach
- `Canvas` struct: `id: UUID`, `type: CanvasType` (`.gameOfLife` | `.video`), `frame: CGRect`, `gameOfLifeConfig`, `videoConfig`
- `CanvasLayout` struct: `name: String`, `canvases: [Canvas]`, Codable, `load(from:)`/`save(to:)`
- `CanvasType` enum: `.gameOfLife`, `.video`
- `GameOfLifeConfig`: `cellSize: Int`, `generationsPerSecond: Double`, `ruleSet: RuleSet`, colors, `gridState`, `paused`
- `VideoConfig`: `videoURL: URL`, `volume: Double`

---

## Phase 0 spike — proven window config (DO NOT DEVIATE)

The S0.1 spike proved this exact config works on macOS Tahoe 26.6.2:

```swift
let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
window.level = NSWindow.Level(rawValue: Int(iconLevel))
window.isOpaque = false
window.hasShadow = false
window.ignoresMouseEvents = true
window.backgroundColor = .clear
window.collectionBehavior = [
    .canJoinAllSpaces,
    .fullScreenAuxiliary,
    .stationary,
    .transient,
    .ignoresCycle
]
window.order(.below, relativeTo: 0)
```

**Why it works on all Spaces:** `.canJoinAllSpaces` tells the window server "mirror this window on every Space." `.stationary` prevents reordering during Space transitions — but since the window exists on every Space already (canJoinAllSpaces), it's always there. They work together: the window stays quiet while being everywhere.

Do NOT use `CGWindowLevelForKey(.desktopIconWindow) - 1` — the design spec used an offset, but the spike proved the raw value is correct. Do NOT remove `.stationary` — it prevents z-order fighting with Finder.

---

## Files to create

All paths relative to:
`./desktop-canvas/Sources/DesktopCanvas/`

### File 1: `CanvasWindow.swift`

An `NSWindow` subclass at the desktop icon level. Houses a plain NSView as content view,
which contains `CanvasRenderer` subviews (one per canvas in the layout).

```swift
import AppKit

final class CanvasWindow: NSWindow {

    private var renderers: [UUID: CanvasRenderer] = [:]
    private var providers: [UUID: any CanvasProvider] = [:]

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        self.level = NSWindow.Level(rawValue: Int(iconLevel))
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.backgroundColor = .clear
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
            .ignoresCycle
        ]

        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = .clear

        self.order(.below, relativeTo: 0)
    }

    func layoutCanvases(_ canvases: [Canvas]) {
        guard let contentView = contentView else { return }

        let newIDs = Set(canvases.map(\.id))
        let oldIDs = Set(renderers.keys)

        // Remove canvases no longer in the layout
        for id in oldIDs.subtracting(newIDs) {
            if let provider = providers[id] {
                provider.detach()
            }
            renderers[id]?.removeFromSuperview()
            renderers[id] = nil
            providers[id] = nil
        }

        // Create / update canvases
        for (index, canvas) in canvases.enumerated() {
            if let existingRenderer = renderers[canvas.id],
               let existingProvider = providers[canvas.id] {
                // Update existing — push new config, reposition
                existingProvider.canvas = canvas
                existingRenderer.frame = canvas.frame
                existingProvider.update()
            } else {
                // Create new provider + renderer
                let provider: any CanvasProvider = switch canvas.type {
                case .gameOfLife:
                    GameOfLifeProvider(canvas: canvas)
                case .video:
                    VideoProvider(canvas: canvas)
                }

                let renderer = CanvasRenderer(provider: provider)
                renderer.frame = canvas.frame
                contentView.addSubview(renderer)
                renderers[canvas.id] = renderer
                providers[canvas.id] = provider
            }
        }

        // Ensure z-order matches array order: first canvas = bottom, last = top
        for (index, canvas) in canvases.enumerated() {
            guard let renderer = renderers[canvas.id] else { continue }
            // Re-add at position to establish correct z-order
            // NSView.order(_:relativeTo:) would work but addSubview already
            // places at the top of the z-stack. We need bottom-first order
            // so we sort by index when adding.
        }
    }
}
```

**Factory pattern:** `layoutCanvases` creates `GameOfLifeProvider` or `VideoProvider` based on
`canvas.type`. This is the sole creation point — no other file creates providers.

**Diff-based update:** Existing providers get their `canvas` property updated and `update()` called.
Only new/deleted canvas IDs trigger creation or destruction. This makes `refresh()` cheap.

**Z-ordering:** The canvases array order determines visual z-order. First canvas (index 0) = bottommost,
last canvas = topmost. Achieved by adding subviews in order — each `addSubview` places at the top,
so we iterate front-to-back and add each renderer, which naturally stacks them correctly.

**Important:** The CanvasRenderer class (Phase 2) calls `provider.attach(to:frame:)` in its `init`.
But here in CanvasWindow, we set `renderer.frame = canvas.frame` AFTER init. The renderer's
initial frame is `.zero`. When we set `.frame`, `setFrameSize` fires → calls `provider.update()`.
The provider needs to handle the initial frame being zero gracefully (or we need to fix the init path).

Actually: the CanvasRenderer init passes `self.bounds` (which is `.zero` at init time) to `attach`.
The provider attaches at `.zero` frame. Then when we set `renderer.frame = canvas.frame`,
`setFrameSize` fires → `provider.update()` → provider resizes. This works. But it means the provider
might briefly render at 0×0. For GameOfLife, the grid will be 1×1 until update. For Video, the
layer frame is 0×0 until update. This is fine — it's a single frame at most.

**Alternative: pass the real frame at construction time.** Modify the CanvasRenderer init to accept
an initial frame, OR modify the provider's init + attach flow. Since we can't modify CanvasRenderer
(this phase only creates CanvasWindow.swift), we'll accept the brief 0×0 frame and rely on
`update()` to fix it immediately. If this causes a visible flash, fix it in a follow-up.

### File 2: `ScreenManager.swift`

Owns one `CanvasWindow` per connected `NSScreen`. Responds to display hot-plug events.
Manages the NSApplication lifecycle.

```swift
import AppKit

final class ScreenManager {
    private(set) var windows: [NSScreen: CanvasWindow] = [:]
    private var layout: CanvasLayout?
    private var displayObserver: NSObjectProtocol?
    private var appIsRunning = false

    func apply(layout: CanvasLayout) {
        self.layout = layout

        // Start NSApplication if not already running
        if !appIsRunning {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            appIsRunning = true
        }

        // Create windows for all currently connected screens
        for screen in NSScreen.screens {
            createWindow(for: screen)
        }

        // Listen for display changes (hot-plug)
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }

        // Enter the run loop (blocks until stop() is called)
        if !NSApp.isRunning {
            NSApp.run()
        }
    }

    func stop() {
        if let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }

        for (_, window) in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        if appIsRunning {
            NSApp.terminate(nil)
            appIsRunning = false
        }
    }

    func refresh() {
        guard let layout = layout else { return }
        for (_, window) in windows {
            window.layoutCanvases(layout.canvases)
        }
    }

    private func createWindow(for screen: NSScreen) {
        guard let layout = layout else { return }
        let window = CanvasWindow(screen: screen)
        window.layoutCanvases(layout.canvases)
        windows[screen] = window
    }

    private func handleScreenChange() {
        // Remove windows for disconnected screens
        let currentScreens = Set(NSScreen.screens)
        for (screen, window) in windows {
            if !currentScreens.contains(screen) {
                window.orderOut(nil)
                windows[screen] = nil
            }
        }

        // Create windows for newly connected screens
        for screen in currentScreens {
            if windows[screen] == nil {
                createWindow(for: screen)
            }
        }
    }
}
```

**Activation policy:** `.accessory` — no Dock icon, no menu bar, but can receive notifications
(needed for `didChangeScreenParametersNotification`). `.prohibited` blocks ALL events including
notifications, so we can't use it.

**NSApp.run():** Called AFTER setting up windows. Blocks until `NSApp.terminate(nil)` is called
by `stop()`. The caller (demo app, or test script) calls `apply()` on a background queue or
main queue — `apply()` takes over the main run loop.

**Display hot-plug:** `didChangeScreenParametersNotification` fires on display connect/disconnect.
`handleScreenChange()` diffs `NSScreen.screens` against our `windows` dictionary:
missing screens → close windows; new screens → create windows.

### File 3: `DesktopCanvas.swift`

Singleton entry point. One-liner API for the demo app.

```swift
import AppKit

final class DesktopCanvas {
    static let shared = DesktopCanvas()

    private var screenManager: ScreenManager?

    private init() {}

    func apply(layout: CanvasLayout) {
        stop()

        // Performance cap: warn if Game of Life cells exceed 10M
        let totalCells = layout.canvases.reduce(0) { count, canvas in
            guard canvas.type == .gameOfLife, let config = canvas.gameOfLifeConfig else {
                return count
            }
            let cols = Int(floor(canvas.frame.width / CGFloat(config.cellSize)))
            let rows = Int(floor(canvas.frame.height / CGFloat(config.cellSize)))
            return count + (cols * rows)
        }

        if totalCells > 10_000_000 {
            print("[DesktopCanvas] WARNING: Total Game of Life cells (\(totalCells)) exceeds recommended limit of 10M. Performance may degrade.")
        }

        let manager = ScreenManager()
        manager.apply(layout: layout)
        self.screenManager = manager

        // Save as last-used preset
        Self.saveLastUsedPreset(layout)
    }

    func stop() {
        screenManager?.stop()
        screenManager = nil
    }

    func refresh() {
        screenManager?.refresh()
    }

    // MARK: - Preset persistence

    static func presetsDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("DesktopCanvas/presets", isDirectory: true)
    }

    static func lastUsedPresetURL() -> URL {
        presetsDirectory().appendingPathComponent("_last_used.json")
    }

    static func saveLastUsedPreset(_ layout: CanvasLayout) {
        let dir = presetsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? layout.save(to: lastUsedPresetURL())
    }

    static func loadLastUsedPreset() -> CanvasLayout? {
        try? CanvasLayout.load(from: lastUsedPresetURL())
    }
}
```

**Performance cap:** Iterates all Game of Life canvases, computes `(frame.width / cellSize) * (frame.height / cellSize)` per canvas, sums up. If total > 10,000,000, prints a warning. Does NOT block — this is a soft cap for the editor to respect. The computation uses `floor` like `GameOfLifeProvider.setupGrid()` for consistency.

**Preset paths:** `~/Library/Application Support/DesktopCanvas/presets/_last_used.json` — auto-saved on every `apply()`. Loaded by demo app on launch. `CanvasLayout` has `save(to:)` and `load(from:)` already (Phase 1).

---

## Verification

```bash
cd "./desktop-canvas"
swift build
```

**Expected:** Build succeeds with zero errors, zero warnings.

### Manual smoke test (after build succeeds)

You can test Phase 5 immediately by adding a temporary test file. This is optional —
the demo app (Phase 8) will be the official test harness.

Create `/tmp/TestDesktopCanvas.swift`:

```swift
import DesktopCanvas

// Conway's Game of Life, 300×200 grid, 4px cells, 30 gen/s
let golConfig = GameOfLifeConfig(
    ruleSet: RuleSet.presets[0],   // Conway
    cellSize: 4,
    aliveColor: CodableColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1.0),
    deadColor: CodableColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0),
    marginColor: CodableColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1.0),
    generationsPerSecond: 30
)

// Full-screen canvas on primary screen
let screen = NSScreen.main!
let golCanvas = Canvas(
    type: .gameOfLife,
    frame: screen.frame,
    gameOfLifeConfig: golConfig
)

let layout = CanvasLayout(name: "Phase 5 Test", canvases: [golCanvas])
DesktopCanvas.shared.apply(layout: layout)

// App runs until user sends SIGTERM or calls DesktopCanvas.shared.stop()
```

Run with:
```bash
cd "./desktop-canvas"
swift run -c release /tmp/TestDesktopCanvas.swift
```

Or just verify the types resolve: add the test, compile with `swift build`, confirm no errors.

---

## Out of scope

- Do NOT modify any existing file. You create THREE files: `CanvasWindow.swift`, `ScreenManager.swift`, `DesktopCanvas.swift`
- No demo app (Phase 8)
- No grid editor (Phase 10)
- No overlap resolver (Phase 6)
- No tests (Phase 12)

---

## Filesystem layout after completion

```
desktop-canvas/
├── Package.swift
├── Sources/
│   └── DesktopCanvas/
│       ├── CodableColor.swift              ← Phase 1
│       ├── CanvasLayout.swift              ← Phase 1
│       ├── Canvas.swift                    ← Phase 1
│       ├── RuleSet.swift                   ← Phase 1
│       ├── CanvasProvider.swift            ← Phase 2
│       ├── CanvasRenderer.swift            ← Phase 2
│       ├── GameOfLifeProvider.swift        ← Phase 3
│       ├── VideoProvider.swift             ← Phase 4
│       ├── CanvasWindow.swift              ← NEW (this phase)
│       ├── ScreenManager.swift             ← NEW (this phase)
│       └── DesktopCanvas.swift             ← NEW (this phase)
├── Spike/                                  ← do NOT touch
├── docs/                                   ← do NOT touch
```

---

## Phase 0 recap (why these exact values)

| Decision | Value | Why |
|---|---|---|
| Window level | `CGWindowLevelForKey(.desktopIconWindow)` raw | Behind icons, Mission Control survives, Spaces works |
| Collection behavior | `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient, .ignoresCycle` | Every Space, no flicker, no Cmd+Tab, no Mission Control thumb |
| Activation policy | `.accessory` | No Dock icon, but can receive hot-plug notifications |
| Z-order within window | Array index order | First canvas = bottom, last = top. Natural, predictable |
| Provider creation | Factory in `CanvasWindow.layoutCanvases` | Single creation point, switch on type |
| Per-screen windows | One `CanvasWindow` per `NSScreen` | Clean display lifecycle, natural coordinate spaces |