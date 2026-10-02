# Phase 4: Video Provider — Agent Prompt

## Your task

Implement `VideoProvider` — an AVPlayer-based content provider that plays MP4 videos inside a
desktop canvas. This file conforms to the `CanvasProvider` protocol (already in the codebase).
Handles seamless looping, missing file errors, volume control, and proper cleanup.

This phase creates **one file**: `Sources/DesktopCanvas/VideoProvider.swift`.
Your sibling agent is simultaneously working on Phase 3: `GameOfLifeProvider.swift` (a different file).
No conflicts — you never touch the same file.

After done: `swift build` must pass with zero errors, zero warnings.

---

## Project context

**Repo root:** `./`
**Module:** `desktop-canvas/`
**What:** DesktopCanvas renders dynamic content behind macOS desktop icons. MP4 videos + Game of Life.

### What already exists (Phases 0–2 done, builds clean)

```
desktop-canvas/
├── Package.swift                              ← Swift 5.9, macOS 13+, links AppKit/Metal/AVFoundation/QuartzCore
├── Sources/
│   └── DesktopCanvas/
│       ├── CodableColor.swift                 ← raw RGBA struct, Codable
│       ├── CanvasLayout.swift                 ← name + [Canvas], load/save JSON
│       ├── Canvas.swift                       ← Canvas, CanvasType, GameOfLifeConfig, VideoConfig
│       ├── RuleSet.swift                      ← 9 presets, B3/S23 parser
│       ├── CanvasProvider.swift               ← protocol: attach/detach/update/pause/resume
│       └── CanvasRenderer.swift               ← NSView wrapper, clips to bounds
```

### Key types you'll use (read-only — do NOT modify these files)

- `CanvasProvider` protocol: `var canvas: Canvas { get set }`, `attach(to:frame:)`, `detach()`, `update()`, `pause()`, `resume()`
- `Canvas` struct: `id: UUID`, `type: CanvasType`, `frame: CGRect`, `gameOfLifeConfig: GameOfLifeConfig?`, `videoConfig: VideoConfig?`
- `VideoConfig`: `videoURL: URL`, `volume: Double` (0.0–1.0), `loop: Bool`
- `CanvasType.video` — the enum case you should expect

---

## Phase 0 spike reference (S0.5 — proven to work)

The S0.5 spike at `desktop-canvas/Spike/LoopTest/Sources/main.swift` proved:
- `player.actionAtItemEnd = .none` + `NotificationCenter` listener for `.AVPlayerItemDidPlayToEndTime`
  → `seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)` → `play()` produces seamless loops
- Loop gap is ~55ms (~3 frames at 60fps) — barely noticeable, acceptable for desktop canvas
- Volume 0.0 by default prevents unexpected audio
- S0.2 spike confirmed AVPlayerLayer works in a desktop-level window behind icons

Key patterns from the spike:
```swift
player = AVPlayer(playerItem: playerItem)
player.actionAtItemEnd = .none
player.volume = 0.0  // default silent

playerLayer = AVPlayerLayer()
playerLayer.player = player
playerLayer.frame = contentView.bounds
playerLayer.videoGravity = .resizeAspectFill
contentView.layer?.addSublayer(playerLayer)

// Loop notification
NotificationCenter.default.addObserver(
    self,
    selector: #selector(playerDidFinishPlaying),
    name: .AVPlayerItemDidPlayToEndTime,
    object: playerItem
)

@objc func playerDidFinishPlaying(_ notification: Notification) {
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        self.player.play()
    }
}
```

S0.2 spike confirmed: AVPlayerLayer in a desktop-level window at `kCGDesktopIconWindowLevel` works
perfectly — icons clickable, Mission Control and Spaces survive, no visual artifacts.

---

## File to create

Single file at:
`./desktop-canvas/Sources/DesktopCanvas/VideoProvider.swift`

### Architecture

```
VideoProvider: NSObject (CanvasProvider)
  ├── canvas: Canvas (read/write from protocol)
  ├── player: AVPlayer?
  ├── playerLayer: AVPlayerLayer?
  ├── playerItem: AVPlayerItem?
  ├── placeholderView: NSView? (shown when video file is missing)
  └── Notification observer for .AVPlayerItemDidPlayToEndTime
```

### Why NSObject?

`VideoProvider` must be a class (`CanvasProvider` has `AnyObject` constraint) AND it needs
`@objc` selector exposure for the `AVPlayerItemDidPlayToEndTime` notification handler.
`NSObject` provides both. Alternatively: use block-based notification observation
(`addObserver(forName:object:queue:using:)`) and be a plain class. Either approach works.

**Recommendation:** Use block-based observation to avoid `@objc` and keep the class clean:

```swift
final class VideoProvider: CanvasProvider {
    private var loopObserver: NSObjectProtocol?

    func setupLoopObserver() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
    }
}
```

This avoids `NSObject` subclassing and `@objc` — the class just needs to be a `class` (not struct).

### Implementation outline

```swift
import AppKit
import AVFoundation
import QuartzCore

final class VideoProvider: CanvasProvider {
    var canvas: Canvas

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var placeholderView: NSView?
    private var loopObserver: NSObjectProtocol?

    init(canvas: Canvas) {
        self.canvas = canvas
    }

    func attach(to superview: NSView, frame: NSRect) {
        guard let config = canvas.videoConfig else { return }

        let fileExists = FileManager.default.fileExists(atPath: config.videoURL.path)

        if !fileExists || config.videoURL.path.isEmpty {
            showPlaceholder(in: superview, frame: frame)
            return
        }

        let asset = AVAsset(url: config.videoURL)
        let playerItem = AVPlayerItem(asset: asset)

        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        player.volume = Float(config.volume)
        self.player = player

        let layer = AVPlayerLayer()
        layer.player = player
        layer.frame = frame
        layer.videoGravity = .resizeAspectFill
        superview.layer?.addSublayer(layer)
        self.playerLayer = layer

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, let player = self.player else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                if finished { player.play() }
            }
        }

        player.play()
    }

    private func showPlaceholder(in superview: NSView, frame: NSRect) {
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.darkGray.cgColor

        let label = NSTextField(labelWithString: "\u{26A0} Missing Video")
        label.textColor = NSColor.lightGray
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14)
        label.frame = container.bounds
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)

        superview.addSubview(container)
        self.placeholderView = container
    }

    func detach() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil
    }

    func update() {
        // Called when canvas frame changes. Update layer frame.
        playerLayer?.frame = NSRect(origin: .zero, size: canvas.frame.size)
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }
}
```

### Design decisions

1. **Missing file handling**: When `videoURL.path` is empty or the file doesn't exist, render a
   dark gray `NSView` with a centered "⚠ Missing Video" label. This is visible to the user on
   the desktop canvas, making it obvious something needs attention. The provider still attaches
   successfully — it just shows the placeholder.

2. **Seamless looping**: `actionAtItemEnd = .none` prevents the player from stopping when the
   item ends. The `AVPlayerItemDidPlayToEndTime` notification triggers `seek(to: .zero)` with
   zero tolerance (precise seek), then `play()` in the completion handler. This is the exact
   pattern from S0.5, proven to produce ~55ms gaps.

3. **Volume**: Default 0.0 (silent). Read from `config.volume` in `attach`. If the config
   changes while playing, `update()` should sync `player.volume = Float(config.volume)`.

4. **Video gravity**: `.resizeAspectFill` — the video fills the canvas frame completely,
   cropping if aspect ratios don't match. This is the standard for wallpaper/background video.
   If you want to expose this as configurable later, it's a one-line change.

5. **Layer vs subview**: AVPlayerLayer goes into `superview.layer` as a sublayer (not a subview).
   This is standard AVFoundation pattern. The `CanvasRenderer` already has `wantsLayer = true`
   and `masksToBounds = true`, so the layer clips correctly to the canvas bounds.

6. **Retain cycles**: `loopObserver` closure captures `[weak self]`. `detach()` removes the
   observer explicitly (belt) and `deinit` would clean it up too (suspenders). The `playerLayer`
   is not retained by the notification closure — only `player` is captured weakly.

7. **`update()`**: Re-syncs `playerLayer.frame` to match the current canvas size. Also syncs
   volume from config. Called by `CanvasRenderer` when the frame changes.

---

## Verification

```bash
cd "./desktop-canvas"
swift build
```

**Expected:** Build succeeds with zero errors, zero warnings.

Note: You CANNOT run this yet — there's no window to host it (Phase 5). But it must compile.

---

## Out of scope

- Do NOT modify any existing file. You create ONE file: `VideoProvider.swift`
- Do NOT create `GameOfLifeProvider.swift` (your sibling agent handles Phase 3)
- No video playlist (single MP4 only for v0.1)
- No remote URL streaming (local files only)
- No crossfade or two-player setup (gap is acceptable at ~55ms)
- No window management (Phase 5)
- No demo app (Phase 8)
- No tests (Phase 12)

---

## Phase 3 sibling context (what the other agent is building)

Your sibling is creating `GameOfLifeProvider.swift` — a Metal compute + render provider that:
- Conforms to `CanvasProvider` (same protocol)
- IS an MTKView (subclasses MTKView, conforms to MTKViewDelegate)
- Double-buffers grid state (bufferA/bufferB ping-pong)
- Dispatches compute kernel (16×16 threadgroups, toroidal wrapping)
- Fragment shader renders alive/dead/margin colors from CodableColor configs
- Timer drives generation ticks at `generationsPerSecond` rate
- Embeds Metal shader source as a string in the Swift file (no separate .metal file)

Different file, different agent, no conflicts. Your `VideoProvider` and their `GameOfLifeProvider`
both compile against the same `CanvasProvider` protocol and `Canvas` model.