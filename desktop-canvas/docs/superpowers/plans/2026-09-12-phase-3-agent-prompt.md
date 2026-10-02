# Phase 3: Metal Game of Life Provider — Agent Prompt

## Your task

Implement `GameOfLifeProvider` — the Metal compute + render pipeline for Conway's Game of Life
and variant rule sets. This file conforms to the `CanvasProvider` protocol (already in the codebase)
and renders arbitrary grids at any canvas frame size.

This phase creates **one file**: `Sources/DesktopCanvas/GameOfLifeProvider.swift`.
Your sibling agent is simultaneously working on Phase 4: `VideoProvider.swift` (a different file).
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
- `GameOfLifeConfig`: `ruleSet: RuleSet`, `cellSize: Int`, `aliveColor: CodableColor`, `deadColor: CodableColor`, `marginColor: CodableColor`, `generationsPerSecond: Double`, `gridState: [[Bool]]?`, `paused: Bool`
- `RuleSet`: `name: String`, `birth: Set<Int>`, `survival: Set<Int>` (9 presets available as `RuleSet.presets`)
- `CodableColor`: `red: Double`, `green: Double`, `blue: Double`, `alpha: Double`

---

## Decision: embed shader as string

The Metal shader source goes directly in `GameOfLifeProvider.swift` as a multiline string, just like the S0.4
spike did. This avoids SwiftPM resource complications (`.metal` files aren't natively handled by SwiftPM
without Xcode build phases). The string is compiled at runtime via `device.makeLibrary(source:options:)`.

If we want a separate `.metal` file for editing convenience later, that's a copy-paste extraction.
But for now: one file, one source of truth.

---

## Phase 0 spike reference (S0.4 — proven to work)

The S0.4 spike at `desktop-canvas/Spike/GameOfLifeSpike/Sources/main.swift` proved:
- 500×500 grid at 60fps on Apple Silicon
- Double-buffer ping-pong works
- 16×16 threadgroups with `dispatchThreads` (non-uniform grids) works
- Toroidal wrapping (wrapping around edges) works
- Fragment shader with viewport coordinates → grid mapping works
- `drawableSize` (pixels) NOT `bounds` (points) — critical for Retina

Key lessons from Phase 0:
- Set `clearColor` once in init, don't override in `draw(in:)`
- `MTKViewDelegate.draw(in:)` is REQUIRED — NOT `NSView.draw(_:)`
- Must use `drawableSize` for fragment shader uniforms, never `bounds`
- `preferredFramesPerSecond = 0` (let screen drive it) — don't hardcode 60

---

## File to create

Single file at:
`./desktop-canvas/Sources/DesktopCanvas/GameOfLifeProvider.swift`

### Architecture

```
GameOfLifeProvider (CanvasProvider)
  ├── canvas: Canvas (read/write from protocol)
  ├── metalDevice, commandQueue (MTLDevice/Queue)
  ├── mtkView: MTKView (self — GameOfLifeProvider IS the MTKView)
  ├── computePipeline, renderPipeline (MTLCompute/RenderPipelineState)
  ├── bufferA, bufferB: MTLBuffer (uint8, size = cols × rows) — double buffer
  ├── useBufferA: Bool (which buffer is "current" to render)
  ├── timer: DispatchSourceTimer (fires at 1/generationsPerSecond)
  ├── gridWidth, gridHeight: Int (derived from canvas.frame / cellSize)
  └── ruleSetUniform: packed as 2× uint32 bitmasks
```

### Key design choices

1. **GameOfLifeProvider IS the MTKView**: Instead of creating a separate MTKView as a subview,
   the provider itself IS the MTKView. It sets `self.delegate = self` and conforms to
   `MTKViewDelegate`. When `attach(to:frame:)` is called, it sets its own frame and adds itself
   as a subview. When `detach()` is called, it removes itself from superview and invalidates the timer.

2. **Double buffer**: `bufferA` and `bufferB`. Each frame: input = current, output = other.
   Compute writes to output, then `useBufferA.toggle()` so the fragment shader reads the
   newly-computed buffer next frame.

3. **Grid dimensions**: `cols = Int(floor(frame.width / CGFloat(cellSize)))`, same for rows.
   Minimum 1×1 grid.

4. **Grid state**: If `config.gridState != nil`, use that (user-drawn state from editor).
   If nil, initialize with random seed (~50% density). The gridState is size-validated and
   clipped/padded to match actual grid dimensions if mismatched.

5. **Timer**: `DispatchSource.makeTimerSource()`. Schedule at `1.0 / config.generationsPerSecond`
   seconds. Each tick sets `needsCompute = true` and calls `mtkView.setNeedsDisplay(bounds)`.
   `pause()` suspends the timer; `resume()` resumes it. Timer is `.strict` for accuracy.

6. **True rule sets (not hardcoded Conway)**: The compute kernel receives birth/survival as
   two `uint32` bitmasks (e.g., Conway: birth=`0b00001000`=bit 3 set, survival=`0b00001100`=bits 2,3 set).
   The kernel checks: `((birthMask >> aliveNeighbors) & 1) != 0` — no conditional branches for
   arbitrary rules. Extract bitmasks from `RuleSet` in Swift before encoding.

7. **Margin rendering**: Grid is centered in the canvas frame. The fragment shader receives
   the canvas pixel dimensions AND the grid origin offset. Pixels outside the grid render
   `marginColor`. Pixels inside render `aliveColor` or `deadColor`.

8. **`update()`**: Re-derives grid dimensions from the current canvas frame. If dimensions
   changed, reallocates buffers and re-seeds (or preserves existing state by copying into
   new grid). Then triggers a render.

### Implementation outline

```swift
import AppKit
import Metal
import MetalKit

final class GameOfLifeProvider: MTKView, CanvasProvider {
    // Protocol
    var canvas: Canvas

    // Metal
    private var commandQueue: MTLCommandQueue!
    private var computePipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var bufferA: MTLBuffer!
    private var bufferB: MTLBuffer!
    private var useBufferA = true
    private var needsCompute = true

    // Grid
    private var gridWidth: Int = 0
    private var gridHeight: Int = 0

    // Timing
    private var timer: DispatchSourceTimer?
    private var timerQueue: DispatchQueue

    init(canvas: Canvas) {
        self.canvas = canvas
        self.timerQueue = DispatchQueue(label: "com.desktopcanvas.gol.\(canvas.id)")
        let device = MTLCreateSystemDefaultDevice()!
        super.init(frame: .zero, device: device)
        self.delegate = self
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.framebufferOnly = false
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.wantsLayer = true
        setupMetal()
    }

    required init(coder: NSCoder) { fatalError() }

    // ... setupMetal(), setupGrid(), timer management, MTKViewDelegate.draw(in:),
    // CanvasProvider.attach/detach/update/pause/resume ...
}
```

---

## Metal shader (embedded string)

The shader string goes inside `GameOfLifeProvider.swift` as a private static/global:

```metal
#include <metal_stdlib>
using namespace metal;

struct GridParams {
    uint width;
    uint height;
    uint birthMask;
    uint survivalMask;
};

kernel void gameOfLifeStep(
    device const uint8_t* inputGrid  [[buffer(0)]],
    device uint8_t*       outputGrid [[buffer(1)]],
    constant GridParams&  params     [[buffer(2)]],
    uint2                 gid        [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;
    uint idx = gid.y * params.width + gid.x;

    int aliveNeighbors = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(gid.x) + dx;
            int ny = int(gid.y) + dy;
            // Toroidal wrapping
            if (nx < 0) nx = int(params.width) - 1;
            if (ny < 0) ny = int(params.height) - 1;
            if (nx >= int(params.width)) nx = 0;
            if (ny >= int(params.height)) ny = 0;
            uint nidx = uint(ny) * params.width + uint(nx);
            if (inputGrid[nidx] != 0) aliveNeighbors++;
        }
    }

    uint8_t cell = inputGrid[idx];
    if (cell != 0) {
        outputGrid[idx] = ((params.survivalMask >> aliveNeighbors) & 1);
    } else {
        outputGrid[idx] = ((params.birthMask >> aliveNeighbors) & 1);
    }
}

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    return out;
}

struct FragmentParams {
    uint gridWidth;
    uint gridHeight;
    float cellSize;
    float viewWidth;
    float viewHeight;
    float4 aliveColor;
    float4 deadColor;
    float4 marginColor;
};

fragment float4 gameOfLifeFragment(
    VertexOut               in       [[stage_in]],
    constant FragmentParams& params   [[buffer(0)]],
    device const uint8_t*   grid     [[buffer(1)]]
) {
    float2 fragPos = in.position.xy;
    fragPos.y = params.viewHeight - fragPos.y;

    uint col = uint(floor(fragPos.x / params.cellSize));
    uint row = uint(floor(fragPos.y / params.cellSize));

    if (col >= params.gridWidth || row >= params.gridHeight) {
        return params.marginColor;
    }

    uint idx = row * params.gridWidth + col;
    return grid[idx] ? params.aliveColor : params.deadColor;
}
```

### Key shader details

- **Rule mask encoding**: Swift host converts `RuleSet.birth` and `RuleSet.survival` into `UInt32` bitmasks.
  For Conway: birth `{3}` → `1 << 3 = 0b1000`, survival `{2,3}` → `(1<<2)|(1<<3) = 0b1100`.
  The kernel checks `(mask >> aliveNeighbors) & 1` — single bitwise op, no branches.

- **Color encoding**: Convert `CodableColor` to `float4(red, green, blue, alpha)` in the FragmentParams struct.
  UNUSED: the `clearColor` from init. The fragment shader fills every pixel.

- **Y-flip**: `fragPos.y = viewHeight - fragPos.y` because Metal's coordinate origin is top-left
  but `in.position` uses bottom-left. Critical for correct grid mapping.

- **Compute dispatch**: `dispatchThreads(MTLSize(width: gridWidth, height: gridHeight, depth: 1),
  threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))` — handles non-multiple-of-16 grids.

---

## Performance constraints

- Cell grid limit: 10 million total across all canvases. Enforced in Phase 5 (DesktopCanvas.swift),
  not here. This provider handles any grid size up to GPU memory limits.
- `preferredFramesPerSecond = 0` — adaptive refresh, doesn't fight ProMotion displays.
- Buffer storage mode: `.storageModeShared` (CPU-writable, GPU-readable) for grid buffers.

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

- Do NOT modify any existing file. You create ONE file: `GameOfLifeProvider.swift`
- Do NOT create `VideoProvider.swift` (your sibling agent handles Phase 4)
- Do NOT create `Shaders.metal` (shader is embedded in the Swift file)
- No window management (Phase 5)
- No demo app (Phase 8)
- No grid editor (Phase 10)
- No tests (Phase 12)

---

## Phase 4 sibling context (what the other agent is building)

Your sibling is creating `VideoProvider.swift` — an AVPlayer-based provider that:
- Conforms to `CanvasProvider` (same protocol)
- Creates AVPlayer + AVPlayerLayer in `attach(to:frame:)`
- Handles `AVPlayerItemDidPlayToEndTime` → seek to zero for looping
- Shows gray placeholder view if video file is missing
- Sets volume from config (default 0.0)
- Removes layer and stops player in `detach()`

Different file, different agent, no conflicts. Your `GameOfLifeProvider` and their `VideoProvider`
both compile against the same `CanvasProvider` protocol and `Canvas` model.