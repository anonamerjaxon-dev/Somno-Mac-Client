# DesktopCanvas

Desktop wallpaper and procedural art module — render animated content behind
desktop icons with native performance and zero input interference.

## What it does

Replaces the static macOS desktop wallpaper with dynamic content:
- **Video canvases**: MP4/MOV playback via AVPlayer
- **Game of Life canvases**: GPU-accelerated cellular automata via Metal compute

Canvases are placed freely on the desktop, persist across Spaces and Mission Control,
and sit **behind** desktop icons so Finder interaction works normally.

## Architecture

```
desktop-canvas/
├── Sources/
│   ├── DesktopCanvas/          ← Library (stable, proven)
│   │   ├── Canvas.swift        — CanvasModel, CanvasType, GameOfLifeConfig, VideoConfig, CodableColor
│   │   ├── CanvasLayout.swift  — Persistable layout (name + [CanvasModel] + backgroundColor), save/load to JSON
│   │   ├── BrushTool.swift     — Pure grid algorithms (Bresenham line, rect, flood fill, seed), no Metal/AppKit
│   │   ├── CanvasProvider.swift— Protocol for content providers (attach/detach/update/pause/resume)
│   │   ├── CanvasRenderer.swift— NSView wrapper, delegates lifecycle to provider
│   │   ├── CanvasWindow.swift  — Desktop-level NSWindow per screen (kCGDesktopIconWindowLevel)
│   │   ├── ScreenGeometry.swift — Coordinate mapping between layout, per-screen windows, editor preview
│   │   ├── ScreenManager.swift — NSScreen listener, per-screen window lifecycle, hot-plug
│   │   ├── DesktopCanvas.swift — Public API: apply(layout:), stop(), refresh(with:), presets
│   │   ├── GameOfLifeProvider.swift — Metal compute kernel for Conway + 9 rule variants
│   │   ├── VideoProvider.swift — AVPlayer + AVPlayerLayer, seamless loop, occlusion-aware
│   │   ├── OverlapResolver.swift — Overlap validation and push-apart resolution
│   │   └── RuleSet.swift       — Game of Life rule definitions (B3/S23 notation), 9 presets
│   │
│   ├── DesktopCanvasDemo/      ← Demo/editor app (SwiftUI)
│   │   ├── EditorState.swift   — ObservableObject: single source of truth, UUID-based mutations
│   │   ├── EditorView.swift    — Main window: toolbar + canvas list + settings panel
│   │   ├── CanvasListView.swift— Canvas list with add/remove/reorder
│   │   ├── CanvasSettingsView.swift — Settings panel: position/size, type picker, config
│   │   ├── GridEditorView.swift — In-app grid editor: draw, patterns, zoom/pan, live sync
│   │   ├── PresetManagerView.swift — Save/load/delete canvas layout presets
│   │   ├── VisualLayoutView.swift — Scaled desktop preview: drag, resize, snap feedback
│   │   ├── SnapEngine.swift    — Snap to screen edges, center, canvas edges, layout grid
│   │   ├── ColorWell.swift     — NSColorWell bridge for SwiftUI
│   │   └── main.swift          — SwiftUI app entry point
│   │
│   └── DesktopCanvasTest/      ← Headless smoke test harness
│
├── Tests/DesktopCanvasTests/   ← XCTest suite (112 tests)
│
├── Spike/                       ← Research spikes (reference, do not modify)
│   └── REPORT.md                — Phase 0 findings: window levels, Metal pipeline, compositing
│
└── docs/superpowers/
    ├── specs/                   — Design specification
    └── plans/                   — Phase implementation plans
```

## Quick start

```bash
# Build the library + demo app
cd desktop-canvas
swift build

# Run the demo editor
swift run DesktopCanvasDemo

# Run the headless smoke test
swift run DesktopCanvasTest

# Run the unit test suite
swift test
```

## Coordinate spaces

**One convention: bottom-left origin, y grows up.** Every space below shares it,
so nothing flips y. Getting this wrong is what puts canvases on the wrong display
or mirrors them vertically.

| Space | Origin | y direction | Used by |
|---|---|---|---|
| Canvas / layout | bottom-left of the **primary** display | up | `CanvasModel.frame`, preset JSON |
| `CanvasWindow` content view | bottom-left of **its own** `NSScreen` | up | desktop rendering |
| Editor preview (`LayoutNSView`) | bottom-left of the union of all screens | up | `VisualLayoutView` |
| Game of Life grid | row 0 at the **top** | row index grows down | grid editor **and** the desktop shader |

Because the window is placed at `screen.frame`, and `NSScreen.frame` uses the same
space as the stored layout, the window path is a pure translation. The preview
view does not override `isFlipped`, so it is y-up too and needs only a scale and
translate. Both mappings live in `ScreenGeometry` and are covered by
`Tests/DesktopCanvasTests/OverlapMathTests.swift`; the grid rendering is pinned by
`GameOfLifeOrientationTests`.

> If you add a view that draws the layout, leave it **unflipped** and let
> `ScreenGeometry` do the mapping. Flipping in one place and not the other is
> exactly what produced lessons 0b and 0c below.

## Demo app usage

1. **Add a canvas** — click `+` and choose Game of Life or Video
2. **Position it** — drag in the visual layout view; snaps to screen edges, other canvases, and grid
3. **Configure** — select a canvas to edit settings (cell size, colors, video file, etc.)
4. **Apply to Desktop** — renders behind desktop icons, persists across Spaces
5. **Stop** — removes all canvases from the desktop

### Keyboard shortcuts
- **P** — Pencil tool
- **L** — Line tool
- **R** — Rectangle tool
- **E** — Eraser
- **G** — Toggle grid lines
- **Space** — Rotate selected pattern

### Grid Editor
1. **Open**: select a Game of Life canvas in the canvas list, then click "Edit Grid" in settings
2. **Draw**: select a tool (Pencil/Line/Rectangle/Eraser), click and drag on the grid
3. **Place patterns**: choose from 16 patterns (Glider, Blinker, Pulsar, Gosper Gun, etc.), click to place
4. **Live sync**: cells appear instantly on the desktop canvas — no need to close the editor
5. **Play/pause**: toggle simulation while editing to preview pattern behavior
6. **Zoom/pan**: scroll to zoom (0.25x–32x), right-drag to pan
7. **Rotation**: select a pattern and press Space to rotate 90° before placing

### Preset Manager
1. **Save**: click Presets → enter a name → Save — captures all canvases + positions + background color
2. **Load**: click any saved preset to apply it to the desktop
3. **Delete**: click the trash icon on a preset card
4. Presets include: canvas count, last modified date, background color
5. Stored at `~/Library/Application Support/DesktopCanvas/presets/`

### Snap helpers
- Snap to screen edges, center, adjacent canvas edges, or grid (6pt default threshold)
- **x and y are snapped independently.** A vertical edge only ever considers x
  targets and a horizontal edge only y targets, so a canvas can no longer jump
  onto a number that describes the other axis (e.g. an x origin landing on the
  screen's mid-height).
- Hold **⌘** to temporarily disable snapping
- **Fill Screen** button: fills the entire screen (aspect-fill for video, cell-size-snapped for GoL)
- Grid snapping generates targets at every `layoutGridSize` multiple across the screen, so the toolbar toggle really snaps
- Adjacent canvases are offered at both a flush edge and a `margin` gap
  (`margin` is the same value the editor draws its guide lines at). When an
  explicit edge snap wins during a resize, it is honoured even if it breaks the
  Game of Life cell-size multiple — the snap you aimed at beats a whole number
  of cells.
- Dragging a canvas onto another pushes it clear instead of overlapping; a red border flashes to show the collision was prevented (hold **⌘** to override)

## Current state (Phases 9–11 complete)

### ✅ Working
- **Desktop-level rendering** at `kCGDesktopIconWindowLevel` (behind icons, survives Spaces, Mission Control, Show Desktop)
- **Multi-screen support** with hot-plug detection — each display gets only the canvases that intersect it
- **Game of Life**: Metal GPU compute, 9 rule sets, configurable cell size/colors/speed
- **Video playback**: AVPlayer with seamless looping, space-aware pause/resume
- **Visual layout editor** with drag/resize and snap feedback
- **UUID-based state management** (no index-out-of-range crashes)
- **JSON preset save/load** with `_last_used.json` auto-restore
- **Preset Manager UI** (Phase 9): save named presets, load, delete, metadata display (name, canvas count, modified date)
- **Grid Editor** (Phase 10): draw cells with Pencil/Line/Rectangle/Eraser tools, place 16 patterns (Glider, Blinker, Pulsar, Gosper Gun, etc.), zoom (0.25x–32x) and pan (right-drag), pattern rotation, keyboard shortcuts (P/L/R/E/G/Space), play/pause simulation in-editor
- **Live sync** (Phase 10): grid edits appear on desktop GoL in real-time without closing the editor
- **Sleep/wake handling** (Phase 11): auto-pause on system sleep, auto-resume + window reorder on wake
- **Space-switch recovery** (Phase 11): GoL rendering resumes on MTKView visibility change
- **Low power mode** (Phase 11): auto-detects `NSProcessInfo.isLowPowerModeEnabled`, drops fps from 60→30
- **Background fill** (Phase 11): solid color fill behind canvases via ColorPicker in toolbar, persists with presets
- **Rule set picker** (Phase 11): 9 preset rule sets (Conway, HighLife, Seeds, Maze, etc.) with live GPU recompute on change
- **Bug fixes** (Phase 11): all 8 review bugs resolved — NSApp lifecycle, timer state tracking, JSON decode clamping, clipsToBounds, cell cap enforcement, AVPlayerLayer zero-frame init
- **Single-window-per-screen** architecture (no z-ordering, no overlapping — by design)

### Testing
`swift test` runs 112 XCTest cases covering Codable round-trips, corrupt-JSON
rejection, rule-set parsing, the pure `BrushTool` algorithms (including a
reference CA stepper), overlap math, `cellSize` clamping, `ApplyResult`
paths, and the screen/preview coordinate mappings.

### Rule sets

9 preset cellular automata rules, switchable live from settings panel:

| Rule | Notation | Character |
|---|---|---|
| **Conway** | B3/S23 | Classic — gliders, oscillators, stable structures |
| **HighLife** | B3,6/S23 | Like Conway + self-replicating patterns |
| **Day & Night** | B3,6,7,8/S3,4,6,7,8 | Inversion-symmetric, same behavior when flipped |
| **Seeds** | B2/S | Explosive chaos — nothing survives, new cells from pairs |
| **Maze** | B3/S1,2,3,4,5 | Produces maze-like corridors |
| **Anneal** | B4,6,7,8/S3,5,6,7,8 | Coagulating blobs and organic shapes |
| **2×2** | B3,6/S1,2,5 | Blocky, square-based patterns |
| **Morley** | B3,6,8/S2,4,5 | Very active, prolific glider producer |
| **Diamoeba** | B3,5,6,7,8/S5,6,7,8 | Diamond-shaped crystalline growth |

### Known limitations
- **MP4 codec support**: Some MP4 files use codecs that AVPlayerLayer can decode audio from but won't render video frames (the player state is `.readyToPlay` but `presentationSize` is `.zero`). Converting to MOV usually resolves this. The editor shows a "⚠ Playback failed" placeholder when this occurs.
- **Video aspect ratio**: The player layer uses `AVLayerVideoGravity.resizeAspectFill`, so a video whose aspect ratio differs from its canvas is cropped to fill. Resizing a video canvas is therefore free-form — it is not locked to the video's natural proportions.
- **No desktop interaction**: `ignoresMouseEvents = true` always. The architecture allows adding click-through later.
- **macOS 13+**: Requires Ventura or newer (uses modern AVFoundation async APIs).

## Lessons learned (mistakes worth documenting)

### 0. Video aspect lock was documented but never implemented
**Problem:** The README claimed video canvases were "aspect-ratio locked" and that resizing preserved natural proportions, but `VideoProvider` hardcoded `videoGravity = .resizeAspectFill` and nothing constrained the canvas size. The docs described an intent the code never had.
**Fix:** The claim was removed and the actual behaviour documented as a known limitation. `VideoProvider` still fills the canvas — cropping, not letterboxing.

### 0b. Two coordinate conventions where there should have been one
**Problem:** The editor preview was vertically mirrored against the desktop: a canvas near the bottom of the screen (the dock side) drew near the *top* of the editor. Two bugs stacked. `previewRect` flipped y, and the offset it was handed already folded in the screen-union origin, so the union was subtracted a second time. `LayoutNSView` never overrides `isFlipped`, so it is y-up like the desktop — the flip was never needed. The old README entry asserted the wrong convention, so the docs "confirmed" the bug.
**Fix:** `ScreenGeometry`'s doc comment now states the one convention: layout frames, `NSScreen.frame`, `NSWindow` content views and the editor preview are **all** bottom-left, y-up. `previewRect(for:scale:offset:)` and `canvasPoint(fromViewPoint:scale:offset:)` only scale and translate — the union origin already lives in the offset, so they no longer take a `unionFrame`. `OverlapMathTests` pins the orientation, the round trip, the agreement with `localFrame`, and a negative (multi-display) union origin.

### 0c. The Game of Life grid was mirrored between the editor and the desktop
**Problem:** `GridCanvasNSView` overrides `isFlipped` to `true`, so the editor draws grid row 0 at the top. The fragment shader *also* flipped y (`fragPos.y = viewHeight - fragPos.y`) on top of Metal's already top-left-origin `[[position]]`, so row 0 rendered at the **bottom** of the desktop canvas. Every pattern drawn in the editor came out upside down on the desktop.
**Fix:** The shader indexes rows straight from `in.position.xy`; `viewHeight` was removed from the fragment params. `GameOfLifeOrientationTests` renders a single alive row through the real pipeline and reads the drawable back, so re-introducing the flip fails the suite instead of silently mirroring the grid.

### 0d. Rule: any new view that draws the layout
Keep every layout view **unflipped** (`isFlipped == false`) and let `ScreenGeometry` be the only place that maps stored frames to view coordinates. If a view genuinely must be flipped, flip inside its own drawing and keep the mapping flip-free — flipping in one place and not the other is exactly what produced 0b and 0c. Both regressions are covered by tests; run `swift test` after touching any coordinate code.

### 0e. Snapping: keep the axes apart, and keep the drawn guide honest
**Problem:** Three snap defects shared one root cause — the engine treated a frame as a bag of numbers instead of two independent axes. `candidateSnapTargets` merged x and y values into one flat list, so an origin could snap to the screen's mid-height while checking for an x match (and vice versa), pulling canvases to invisible positions. A second cause: `margin` was stored on `SnapEngine` but never read, while the editor's `buildSnapGuides` overlay *did* honour it — so a guide line appeared for a snap that never fired. Third, only the aspect-locked video path ever consulted screen edges; a Game of Life corner just grid-rounded and so could never be dragged flush to a screen edge.
**Fix:** `snappedCoordinate(_:axis:excluding:)` takes a `SnapAxis`, and `candidateSnapTargets` returns separate `x` and `y` arrays; the margin offsets (`maxX + margin`, `minX - margin`, …) are offered as real targets; the drawn guide now reports the same offset number the snap uses; and `snapCornerResize` records whether an edge snap won and lets it override the cell-size rounding.
**Lesson:** When a snap "does nothing" but a guide line is drawn, the guide and the snap are computing different target lists — make them share one function. Note this bug class is the same family as 0b/0c: it was a coordinate-axis mix-up, not a math error. Covered by 12 tests in `Tests/DesktopCanvasTests/SnapEngineTests.swift` ("Axis independence", "Margin adjacency", "Resize snapping").

### 1. Defer playback until layer is sized
**Problem:** Starting `player.play()` in `attach()` when the AVPlayerLayer frame is `.zero` (before `CanvasRenderer.setFrameSize` fires) causes the decoder to skip video initialization. Only audio plays.
**Fix:** Playback is deferred to `update()` via a `playbackDeferred` flag. The layer is properly sized by then.

### 2. Auto-apply must be async
**Problem:** `autoApplyIfNeeded()` ran synchronously inside SwiftUI binding updates, calling `CanvasWindow.layoutCanvases` which mutates NSView frames. AppKit's dispatch sources get disposed mid-layout → `_dispatch_queue_xref_dispose` crash.
**Fix:** Debounced `DispatchWorkItem` dispatched to the next runloop iteration. Previous work item is cancelled on rapid mutations.

### 3. Structs don't propagate mutations
**Problem:** `VideoProvider` was setting `canvas.videoConfig?.naturalSize` on its local `CanvasModel` copy. `CanvasModel` is a value type — the mutation never reached `EditorState`.
**Fix:** Resolution is read at file-selection time in `EditorState.setVideoURL()`, which owns the source of truth.

### 4. UUID-based state access beats index-based
**Problem:** `CanvasSettingsView` used `state.canvases[index].videoConfig` with indices. When a canvas was added/removed, the index became stale → `Index out of range` crash.
**Fix:** All settings panel mutations go through `mutateCanvas(by: UUID)`, `mutateGoLConfig(by: UUID)`, `mutateVideoConfig(by: UUID)`. These re-resolve the index on each access.

### 5. AVPlayerLayer occlusion is space-aware
**Problem:** Video paused when the demo app window gained focus, then didn't resume when switching back to the desktop Space.
**Fix:** `NSWindow.didChangeOcclusionStateNotification` observer checks `.visible` flag and plays/pauses accordingly.

### 5b. The observer has to be installed after the view has a window
**Problem:** `VideoProvider.observeWindowOcclusion` did `guard let window = superview.window else { return }`, but `attach` runs from `CanvasRenderer.init` — before the renderer is added to any window's content view — so `window` was always nil and the observer was never installed. Video then played even on a fully covered Space.
**Fix:** `installOcclusionObserverIfPossible()` is idempotent and called from both `attach` and `update`, so it succeeds on the first `update` after the view lands in a window. It also applies the current occlusion state immediately, since the notification only fires on a *change*.

### 6. AVFoundation async APIs, not semaphores
**Problem:** `DispatchSemaphore.wait()` blocks the main thread while waiting for `loadTracks` completion. Deprecated property access on `AVAssetTrack` (naturalSize, preferredTransform).
**Fix:** `loadTracks` completion handler launches a `Task { @MainActor in ... }` that awaits `track.load(.naturalSize)` and `track.load(.preferredTransform)` — fully async, no deprecation warnings.

### 7. AVPlayerLayer at .zero before layout
**Problem:** `VideoProvider.attach()` created the AVPlayerLayer at `superview.bounds` which was `.zero` during `CanvasRenderer.init`. The layer was resized in `update()` but the 0×0 window could cause decoder initialization issues.
**Fix:** Layer frame is now derived from `canvas.frame.size` (enforced ≥ 32×32 by `CanvasModel.init`) instead of the transient superview bounds.

### 8. `apply(layout:)` is not a refresh
**Problem:** The editor called `apply(layout:)` on every mouse-up to commit a drag. `apply` stops every window and builds new ones, so a drag restarted video playback and every running simulation — and it dropped `backgroundColor` and the `ApplyResult` overlap error on the floor. `Spike/REPORT.md` flags window teardown mid-drag as a crash risk.
**Fix:** Drags commit through `EditorState.refreshDesktop()` → `DesktopCanvas.refresh(with:)`, which re-frames live windows and providers in place, carries `backgroundColor`, and surfaces overlaps as a status warning. `apply` is now reserved for genuine full (re)builds.

### 9. Corrupt JSON must not be able to trap the process
**Problem:** `Int(Double.infinity)` traps, and `Int(floor(width / CGFloat(cellSize)))` traps when a preset file declares `"cellSize": 0`. A hand-edited or truncated preset file was a hard crash.
**Fix:** `GameOfLifeConfig` clamps `cellSize` to 2…1024 in `init` *and* in `init(from:)`, and `GameOfLifeConfig.gridDimensions(for:cellSize:)` guards non-finite geometry and returns at least 1×1. Every division site goes through it. Tests decode deliberately corrupt preset JSON.

### 10. SwiftUI updates are not free
**Problem:** `GridCanvasNSView.grid` bumped a generation counter in `didSet`, and `updateNSView` assigned it unconditionally. Every SwiftUI update — a hover, a tool switch, a status-bar redraw — therefore invalidated the cached grid bitmap and rebuilt it.
**Fix:** `GridCanvasNSView.apply(grid:…)` compares before assigning and only invalidates the bitmap when the grid or the appearance actually changed.

## License

Proprietary — Somno Mac Client internal module.