# Phase 2: CanvasProvider Protocol & CanvasRenderer — Agent Prompt

## Your task

Implement Phase 2 of DesktopCanvas: the `CanvasProvider` protocol and `CanvasRenderer` view.
This is the abstraction layer between content providers (Game of Life, Video) and the desktop window.
Two files, ~60 lines total. Pure scaffolding — the real rendering lives in Phases 3 and 4.

After you're done, verify with `swift build` in the desktop-canvas directory. Must compile with zero errors and zero warnings.

---

## Project context

You're working on the **Somno Mac Client** monorepo at:

```
./
```

**DesktopCanvas** renders dynamic content (MP4 videos + Game of Life procedural art) behind macOS desktop icons, using a desktop-level `NSWindow`. Think "video wallpaper" + "Conway's Game of Life art" on the desktop.

### What already exists (Phase 1 — done)

Phase 1 created the Package.swift and data models. These files already exist and compile:

```
desktop-canvas/
├── Package.swift                              ← Swift 5.9, macOS 13+, links AppKit/Metal/AVFoundation/QuartzCore
├── Sources/
│   └── DesktopCanvas/
│       ├── CodableColor.swift                 ← raw RGBA struct, Codable, Equatable
│       ├── CanvasLayout.swift                 ← name + [Canvas], load/save JSON
│       ├── Canvas.swift                       ← CanvasType, GameOfLifeConfig, VideoConfig, Canvas (Codable via [Double] for CGRect)
│       └── RuleSet.swift                      ← 9 presets, B3/S23 parser/generator
├── Spike/                                     ← Phase 0 research spikes (do NOT touch)
├── docs/                                      ← design specs (do NOT touch)
```

Key facts from Phase 1 you'll need:
- `Canvas` conforms to `Codable` and `Identifiable`, has `id: UUID`, `type: CanvasType`, `frame: CGRect`, `gameOfLifeConfig`, `videoConfig`
- `CanvasType` is `.gameOfLife` or `.video`
- `CGRect` is NOT Codable — the manual implementation uses a `[Double]` array `[x, y, width, height]`

### Phase 0 research spikes (for context)

All 5 spikes passed on macOS Tahoe 26.6.2:
- Window level `-2147483603` works behind icons, survives Mission Control and Spaces
- MTKView + AVPlayerLayer coexist without flicker
- No permissions needed
- Metal compute at 500×500 cells runs 60fps
- Video looping has ~55ms seek gap (acceptable)

---

## Decisions already made (do NOT change these)

1. **AppKit import is fine**. Phase 1 used Foundation + CoreGraphics. Phase 2 uses `NSView` and `NSRect`, which require `import AppKit`. Add it.

2. **Protocol includes `pause()` and `resume()`**. The spec only lists `attach`, `detach`, `update`. We're adding `pause()`/`resume()` for performance: Game of Life timers pause when the canvas is hidden, video playback pauses. Small addition now avoids a protocol-breaking change later.

3. **`attach(to:frame:)` uses `NSRect` (CGFloats) — same type family as `Canvas.frame` (CGRect)**. No conversion needed; Swift treats them interchangeably in most contexts.

4. **`CanvasRenderer` is an `NSView` subclass**. It does NOT use `MTKView` or any Metal — it's a plain NSView that clips to bounds and delegates to the provider. Metal rendering happens *inside* the provider's `attach` method (Phase 3), where the provider adds its own MTKView/AVPlayerLayer as subviews.

5. **Empty default implementations for pause/resume**. Providers that don't need pausing don't have to implement it. Use protocol extension.

---

## Architecture

Each canvas on the desktop works like this:

```
CanvasWindow (Phase 5, future)
  └── contentView (NSView)
       ├── CanvasRenderer (this phase — NSView subclass)
       │    └── CanvasProvider (this phase — protocol, implemented by Phases 3 & 4)
       │         └── MTKView or AVPlayerLayer (future)
       └── CanvasRenderer (another canvas)
            └── CanvasProvider (another provider)
                 └── ...
```

- `CanvasRenderer` is positioned at `canvas.frame` within the window
- It holds ONE `CanvasProvider` reference
- It passes `draw(_:)` calls to the provider's `update()`
- It clips subviews to its bounds so content can't bleed into adjacent canvases

---

## Files to create

All paths are relative to repo root:
`./`

### File 1: `desktop-canvas/Sources/DesktopCanvas/CanvasProvider.swift`

```swift
import AppKit

protocol CanvasProvider: AnyObject {
    var canvas: Canvas { get set }

    func attach(to superview: NSView, frame: NSRect)
    func detach()
    func update()
    func pause()
    func resume()
}

extension CanvasProvider {
    func pause() {}
    func resume() {}
}
```

Notes:
- `AnyObject` constraint: providers are classes (GameOfLifeProvider with metal, VideoProvider with AVPlayer). Structs can't hold MTKView/AVPlayer references.
- Default `pause()`/`resume()` are no-ops — providers override if they have pausable state.
- `frame` parameter on `attach` is the NSRect where the content should render. For Game of Life this sets up the MTKView bounds; for Video it sets the AVPlayerLayer frame.

### File 2: `desktop-canvas/Sources/DesktopCanvas/CanvasRenderer.swift`

```swift
import AppKit

final class CanvasRenderer: NSView {
    weak var provider: CanvasProvider?

    init(provider: CanvasProvider) {
        self.provider = provider
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        provider.attach(to: self, frame: self.bounds)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        provider?.update()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            provider?.detach()
        }
    }

    deinit {
        provider?.detach()
    }
}
```

Notes:
- `masksToBounds = true`: clips subviews (MTKView, AVPlayerLayer) to the canvas frame. Prevents content bleeding into adjacent canvases.
- `weak var provider`: the renderer doesn't own the provider. The DesktopCanvas/ScreenManager (Phase 5) holds strong references to all providers.
- `setFrameSize` → `provider.update()`: when the canvas is resized, the provider recalculates its layout.
- `viewDidMoveToSuperview`: auto-detach when removed from view hierarchy. `deinit` is the safety net.
- `fatalError` on `init(coder:)`: we never load CanvasRenderer from a nib/storyboard.

---

## Verification

After creating both files, run:

```bash
cd "./desktop-canvas"
swift build
```

**Expected:** Build succeeds with zero errors, zero warnings.

---

## Filesystem layout after completion

```
desktop-canvas/
├── Package.swift
├── Sources/
│   └── DesktopCanvas/
│       ├── CodableColor.swift            ← Phase 1 (exists, do NOT touch)
│       ├── CanvasLayout.swift            ← Phase 1 (exists, do NOT touch)
│       ├── Canvas.swift                  ← Phase 1 (exists, do NOT touch)
│       ├── RuleSet.swift                 ← Phase 1 (exists, do NOT touch)
│       ├── CanvasProvider.swift          ← NEW (this phase)
│       └── CanvasRenderer.swift          ← NEW (this phase)
├── Spike/                                ← do NOT touch
├── docs/                                 ← do NOT touch
```

---

## Out of scope (do NOT create these)

- `GameOfLifeProvider.swift` (Phase 3 — Metal compute kernel provider)
- `VideoProvider.swift` (Phase 4 — AVPlayer provider)
- `CanvasWindow.swift` (Phase 5 — desktop-level NSWindow)
- `ScreenManager.swift` (Phase 5 — per-screen window lifecycle)
- `DesktopCanvas.swift` (Phase 5 — main entry point)
- `BrushTool.swift` (Phase 10 — grid editor)
- Any `.metal` shader files
- Any demo app, tests, or docs