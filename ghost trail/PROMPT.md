# GhostTrail — Implementation Prompt

## What GhostTrail Is

A macOS library that renders a ghostly visual trail behind windows as you drag them. The trail is a
fading outline of the window's past positions — a "wake" of rectangles tracing the window's movement
path. The trail is rendered **on a screen-level overlay behind the window** (never covering the
window itself), and it works across all spaces.

**Critical difference from CursorTrail:** CursorTrail traces a single point (the cursor). GhostTrail
traces the full rectangular outline of dragged windows. The rendering is fundamentally different —
stroke the perimeter of historical frames, not a polyline through center points.

---

## Reference Implementations

These are proven, working patterns you should copy directly (not re-derive):

### 1. CVDisplayLink setup (from CursorTrail)

The display link callback, retain/release, and main-thread dispatch pattern. Copy this verbatim,
changing only the class name.

```swift
import CoreVideo

// In your main GhostTrail class:
private var displayLink: CVDisplayLink?
private var displayLinkUserInfo: UnsafeMutableRawPointer?

private func startDisplayLink() {
    stopDisplayLink()

    let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
        guard let userInfo else { return kCVReturnError }
        let trail = Unmanaged<GhostTrail>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { [weak trail] in
            trail?.updateTrail()
        }
        return kCVReturnSuccess
    }

    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
    guard let link = displayLink else { return }

    let unmanaged = Unmanaged.passRetained(self)
    displayLinkUserInfo = unmanaged.toOpaque()
    CVDisplayLinkSetOutputCallback(link, callback, displayLinkUserInfo)
    CVDisplayLinkStart(link)
}

private func stopDisplayLink() {
    guard let link = displayLink else { return }
    CVDisplayLinkStop(link)
    displayLink = nil
    if let opaque = displayLinkUserInfo {
        Unmanaged<GhostTrail>.fromOpaque(opaque).release()
        displayLinkUserInfo = nil
    }
}
```

> **Superseded 2026-10-02 by the audit fix round.** This snippet is the *original*
> specification and is kept for provenance, but two of its statements are known-bad and
> are NOT what `Sources/GhostTrail/GhostTrail.swift` does:
>
> 1. **`passRetained` + `release()` in teardown leaks.** The retain is only balanced by
>    `stopDisplayLink()`, which cannot run from `deinit` while the object is retained by
>    its own display link — so a dropped reference left a live display link and a visible
>    overlay forever. The implementation uses `Unmanaged.passUnretained(self)` and
>    serializes teardown against in-flight callbacks with an `NSLock`.
> 2. **`CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)` writes straight into the
>    property, so a failed create leaves `displayLink` nil — and the old `stop()` did
>    `displayLink as! CVDisplayLink`, which trapped on macOS 13/14 exactly in that case.**
>    The implementation checks the `CVReturn` status, stores the link in a typed
>    `CVDisplayLink?` property, and tears down + returns `false` from `start()` when no
>    link can be created.
>
> On macOS 13/14 this path is the only one taken, so the force-cast crashed every
> affected user on first `start()`.

### 2. Overlay window (from CursorTrail TrailWindow)

Borderless, transparent, mouse-ignoring, full-screen overlay at a level **below normal windows** so
the trail never covers the dragged window.

```swift
import SwiftUI

final class TrailWindow: NSWindow {
    let model: TrailModel

    init(configuration: TrailConfiguration = .init()) {
        self.model = TrailModel()
        let contentView = TrailContentView(configuration: configuration, model: model)
        let hostingController = NSHostingController(rootView: contentView)

        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.contentViewController = hostingController
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            self.setFrame(screen.frame, display: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ points: RingBuffer<TrailPoint>) {
        model.trailPoints = points
    }
}
```

For GhostTrail, the window level needs to be **below** normal windows but **above** the desktop.
Consider `kCGDesktopIconWindowLevel` or `NSWindow.Level(rawValue: kCGNormalWindowLevel - 1)` so
the trail is always behind the window being dragged.

### 3. CGWindowList polling (from PolymorphAgent)

Proven way to get window bounds. Layer-0 windows are normal application windows.

```swift
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    return
}
for w in list {
    if (w[kCGWindowLayer as String] as? Int) == 0,
       let bounds = w[kCGWindowBounds as String] as? [String: Any],
       let x = bounds["X"] as? CGFloat,
       let y = bounds["Y"] as? CGFloat,
       let width = bounds["Width"] as? CGFloat,
       let height = bounds["Height"] as? CGFloat,
       let windowID = w[kCGWindowNumber as String] as? CGWindowID {

        let frame = NSRect(x: x, y: y, width: width, height: height)
        // CGWindowList uses top-left-origin Y. Convert to bottom-left for AppKit.
        let convertedY = screenHeight - y - height
        let convertedFrame = NSRect(x: x, y: convertedY, width: width, height: height)
    }
}
```

### 4. RingBuffer (from CursorTrail)

```swift
public struct RingBuffer<T> {
    private var storage: [T?]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var _count: Int = 0
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var isEmpty: Bool { _count == 0 }
    public var count: Int { _count }
    public var first: T? { isEmpty ? nil : self[0] }

    public mutating func append(_ element: T) {
        storage[writeIndex] = element
        if _count == capacity { readIndex = (readIndex + 1) % capacity }
        else { _count += 1 }
        writeIndex = (writeIndex + 1) % capacity
    }

    @discardableResult
    public mutating func removeFirst() -> T? {
        guard !isEmpty else { return nil }
        let element = storage[readIndex]
        storage[readIndex] = nil
        readIndex = (readIndex + 1) % capacity
        _count -= 1
        return element
    }

    public mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        readIndex = 0; writeIndex = 0; _count = 0
    }

    public subscript(index: Int) -> T {
        precondition(index >= 0 && index < count, "Index out of bounds")
        return storage[(readIndex + index) % capacity]!
    }
}
```

### 5. Package.swift pattern (from CursorTrail)

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhostTrail",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GhostTrail", targets: ["GhostTrail"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GhostTrail",
            dependencies: [],
            path: "Sources/GhostTrail",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "GhostTrailDemo",
            dependencies: ["GhostTrail"],
            path: "Examples/GhostTrailDemo"
        )
    ]
)
```

---

## Architecture

```
CVDisplayLink fires each frame
  → GhostTrail.updateTrail()
    → WindowTracker.pollWindows()
      → CGWindowListCopyWindowInfo → filter layer-0 windows
      → get CGRect bounds for each window
      → compare against last-known frame for that windowID
      → if frame changed > threshold: push frame into per-window ring buffer
      → manage lifecycle: add new windows, prune closed windows
    → for each actively-tracked window: fade older frames
    → assemble all frame-ring-buffers into render data
    → GhostTrailWindow.update(allFrames)
      → SwiftUI Canvas renders outlines of historical frames with diminishing opacity
```

### Key data type

Instead of `TrailPoint` (a single point), you need a `TrailFrame` that captures an entire
window outline at a point in time:

```swift
struct TrailFrame {
    let frame: NSRect        // window bounds at this moment
    let timestamp: CFTimeInterval
}
```

The WindowTracker maintains `[CGWindowID: RingBuffer<TrailFrame>]` — one ring buffer per window.

---

## Design Decisions to Make

These are the open questions. **You should ask before implementing.** This prompt is open-ended —
discuss tradeoffs for each and propose an approach.

### Rendering

1. **Edge-only vs filled rect?**
   - Stroke just the perimeter (4 lines forming the rectangle)?
   - Fill the rect with a translucent wash that fades over time?
   - Only the trailing edge (the edge opposite the drag direction)?
   - All edges but trailing edge is more opaque?

2. **How to render overlapping frames?**
   - If the user drags slowly, frames overlap heavily — should they blend additively?
   - Or should we skip frames that are too close to the previous one?

3. **SwiftUI Canvas vs Metal?**
   - SwiftUI Canvas is simpler and works for moderate frame counts
   - Metal would be needed if there are many windows with long trails
   - Start with Canvas, optimize later?

### Window tracking

4. **Which windows get trails?**
   - Only layer-0 (normal app windows)? Skip menus, tooltips, panels?
   - Skip windows owned by this process (the trail overlay itself)?
   - Only windows owned by the frontmost application?
   - All visible windows — if you drag two Finder windows, both get trails?

5. **Movement detection threshold**
   - How many pixels must a window move before a trail frame is captured?
   - Too low = too many frames, performance hit, no visible difference
   - Too high = jerky trail, skips slow drags

6. **Coordinate system**
   - CGWindowList returns top-left-origin Y coordinates
   - AppKit uses bottom-left-origin. Need to convert.
   - Account for screenHeight changing when external monitors connect/disconnect.

### macOS behavior edge cases

7. **Window snapping (auto-sizing)**
   - When a window snaps to half-screen (macOS Sequoia window tiling), the frame jumps
     discontinuously. Should the trail:
     - Clear immediately (abrupt disappearance)?
     - Continue from the new position without connecting?
     - Draw a "teleport" line between old and new position?
     - Fade out quickly over a few frames?

8. **Minimize / Maximize / Zoom**
   - Minimize: window shrinks toward the Dock. Should the trail:
     - Follow the shrinking animation? (hard — need to track the animation frames)
     - Freeze at the pre-minimize position and fade?
     - Clear immediately?
   - Maximize/Zoom (green button): frame changes to fill available space. Same questions.
   - Entering full-screen: window moves to a new Space. Trail should handle the transition.

9. **Multiple spaces / Mission Control**
   - When the user switches spaces, dragged windows might stay on their original space.
   - The overlay window uses `.canJoinAllSpaces` — this means the trail window follows
     the user across spaces. Is this desired?
   - Alternative: render one overlay per space and only show the local space's trails.
   - Mission Control: all windows are visible simultaneously — trail window is probably
     at the wrong z-order. Should we temporarily hide during Mission Control?

10. **Dock / menu bar / Stage Manager**
    - Dock and menu bar are always-on-top. Trail should never cover them.
    - Stage Manager: windows may be grouped. Does this affect tracking?

11. **External displays**
    - Multiple screens, each with its own coordinate space.
    - Should each screen get its own trail overlay window?
    - Or a single giant window spanning the union of all screens?

### Trail lifecycle

12. **When does a trail start?**
    - On mouse-down on a window's title bar? (Hard to detect without event taps)
    - When the window's frame changes for the first time?
    - When the window moves more than a threshold?

13. **When does a trail end?**
    - When the window stops moving — fade out over time?
    - On mouse-up? (Again, hard without event taps)
    - When the window closes or minimizes?

14. **Fade behavior**
    - Time-based: each TrailFrame has a timestamp, frames older than N seconds are removed
    - Count-based: keep last N frames, each frame's opacity = index/N
    - Hybrid: keep up to N frames, but also expire frames older than T seconds

### Customizable features

15. **What should the public API look like?**
    - Builder pattern (like CursorTrail)? `GhostTrail().color(.cyan).length(30).start()`
    - What knobs: frame count, fade duration, stroke width, stroke color, glow, opacity,
      movement threshold, which windows to track, per-window vs combined mode?

16. **Should this be a library or a standalone app?**
    - Library: other modules import GhostTrail
    - Standalone: runs as its own process with its own UI
    - Both: library + demo app (like CursorTrail)

17. **Configuration presets?**
    - Pre-built configs: .subtle (thin, fast fade), .dramatic (thick, slow fade, glow),
      .retro (green monospace aesthetic)?

### Performance

18. **Polling frequency**
    - CVDisplayLink runs at display refresh rate (60/120/144 Hz)
    - CGWindowListCopyWindowInfo at 120Hz — is this too expensive?
    - Should we throttle to a lower rate (30Hz)?

19. **Memory**
    - Per-window ring buffers with N frames. If tracking 20 windows × 100 frames ×
      NSRect = minimal. Not a concern.

### Demo app

20. **What should the demo app include?**
    - Start/Stop button
    - Live preview of configuration changes
    - Color picker, thickness slider, frame count slider
    - Preset selector

---

## Deliverables

1. **GhostTrail library** — in `ghost trail/Sources/GhostTrail/`
2. **GhostTrailDemo app** — in `ghost trail/Examples/GhostTrailDemo/`
3. **Package.swift** — Swift 5.9, macOS 13+
4. **Build must pass** with zero errors and zero warnings: `swift build`
5. **Ask questions first** — don't write code until the design decisions above are resolved.

---

## Constraints

- Swift 5.9, macOS 13+
- No external dependencies (no third-party packages)
- Follow existing conventions: `final` classes, `private` by default, `let` by default,
  `[weak self]` in escaping closures
- Use `guard` for early exits, not `if` nesting
- Keep functions under ~40 lines