# GhostTrail rewrite — engineering notes

Written 2026-10-03. This file records *why* the module is built the way it is,
including the measurements that killed the obvious designs. If you are about to
"simplify" the overlay level or the hole-clipping code, read this first.

The original complaint (verbatim, m00976):

> the ghost trail is taking up so much energy and it's so un efficient and it's
> so not pleasing in aesthetics and how it looks that I really want to rewrite
> it. It's up to you though like do you think building from up from it would be
> better and think about what I actually want and think about especially for
> example, one window covering another window or like window layer and all that
> think about different scenarios, different type of windows

User decisions, recorded in `AGENTS.md` and honoured throughout:

| Question | Answer |
| --- | --- |
| Keep the package or rebuild? | **Keep the package, replace the guts** — same folder, same `import GhostTrail`, same public API. |
| Window layering | **Under the window, but above the desktop** |
| Aesthetic | **Smooth continuous ribbon** |
| Scenarios | **Window snapping / tiling (macOS Sequoia), Resizing not just dragging, Only the window I'm actually touching** |

Explicitly *not* in scope: dragging two windows at once, full-screen / Spaces.

---

## 1. Why the old one looked like a grey smudge

`GhostTrailRenderer` stamped one stroked-or-filled rectangle **per sample**.
Two rectangles of the same window overlap heavily during any drag, so their
alphas compounded into a flat, opaque grey mass. The `.solid` style was worse:
it drew four nested layer paths, each filling *all* rects `0..<N`, multiplying
the effect. `timeBasedOpacity` was a linear `1 - age/fade`, which made the tail
die uniformly instead of trailing off.

**Fix.** `RibbonGeometry` interpolates a single continuous ribbon from the sample
ring, and `ribbonPath(for:)` concatenates every section's four corners in trail
order into **one** subpath region filled with a single `.linearGradient`.
Overlapping geometry inside one filled path cannot compound alpha, because there
is only one fill.

## 2. Efficiency, and what actually costs anything

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`
measured at **0.344 ms/call** over 200 calls on this machine (20 windows returned,
only 3 at layer 0). At the 30 Hz poll rate that is ~1% of one core — the window
list was *not* the energy problem. What was:

- the tracker forced a **single** active window and deleted every other trail
  (`WindowTracker.swift:82-91`, old);
- it compared only `origin`, so **resizing produced no trail at all**;
- nothing distinguished a window the user was touching from a window that
  merely animated open, restored, or snapped — so those drew trails too.

**Fix.** `DragSessionTracker` installs a `.listenOnly` session event tap and only
trails the window the pointer is actually pressing and dragging. `WindowTracker`
now supports **multiple concurrent trails** and filters to `layer == 0` (was
`layer <= 1`). If the tap cannot install — no Accessibility permission — the
library degrades to geometry-only eligibility and sets `isUsingGeometryFallback`
rather than going dark.

## 3. macOS will not composite below normal windows — measured

The single most load-bearing finding in this rewrite.

`/tmp/leveltest.swift` placed a 400×200pt red window at a series of levels and
counted red pixels in a `CGDisplayCreateImage` capture:

| Level | Red pixels | Composited? |
| --- | --- | --- |
| `kCGDesktopWindowLevel` (−2147483623) | 337 | no |
| `kCGDesktopIconWindowLevel` (−2147483603) | 475 | no |
| `kCGNormalWindowLevel − 1` | 475 | no |
| `kCGNormalWindowLevel` (0) | 320,475 | **yes** |
| `.floating` (3) | 240,475 | **yes** |

Activation policy is irrelevant: `/tmp/policytest.swift` ran the same probe
under `.accessory` and `.regular` and got identical results.

So the original `.behindWindows` (`desktopIcon - 1`) was *not* below the
desktop — it was one point **above** the desktop-icon layer, competing with the
wallpaper — and it was invisible anyway. (`PROMPT.md`'s correction block calls
`desktopIcon − 1` "below the desktop"; that is wrong, and this table is the
disproof.)

**Fix.** `GhostTrailWindow` places the overlay at
`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)` — the
probe confirms the window server reports it as `layer=2147483630` — and
**the depth illusion is drawn**: ribbon pixels falling inside a visible normal
or floating window are erased. `.aboveWindows` still maps to `.floating`.

This is why a screenshot of a ribbon dragged across a busy desktop can look
empty. That is the feature working.

## 4. Why holes are a clip region and not extra subpaths

The obvious way to punch holes is to append each occluding rectangle as another
subpath of the ribbon path and fill with the even-odd rule.

**This is wrong**, because ribbon sections already overlap each other, so
even-odd parity-counts the ribbon against *itself*: a point inside two
overlapping sections comes out unfilled. Measured: 18,210 pixels survived an
occluder that covered the entire canvas.

`RibbonClipping` instead builds a **clip region** — one enclosing rectangle with
the hole rectangles nested inside, filled even-odd — and clips with
`GraphicsContext.clip(to:style:)`. Nesting an outer rect around holes leaves
exactly the ring between them.

Two refinements, both measured:

- The enclosing rect is pushed 4096pt beyond the geometry (`outerMargin`).
  A clip edge is antialiased, so an enclosing edge flush with the ribbon's
  bounding box strips a half-covered fringe off the ribbon's extremes —
  4,614 of accumulated alpha missing from a ribbon that was never occluded.
- `WindowOccluders.occludingRects(for:among:slop:)` expands each hole by
  `strokeWidth / 2 + 1`. The head outline is centred on the current window's
  rectangle, so **half its ink lies outside that rectangle**; without the slop,
  1,836 pixels of the outline drew straight across the occluding window's face.

## 5. Snaps are a translation, never a resize

`TrailTuning.classify(_:from:)` was reading `hypotDistance` over origin *and*
size, so a 60pt resize between two 30Hz samples looked like a 60pt jump and was
classified `.snapped` — which discards the trail. During a fast edge drag that
meant no ribbon at all.

```swift
func classify(_ current: TrailSample, from previous: TrailSample) -> MotionKind {
    let move = current.originDelta(from: previous)
    if move >= snapDistance { return .snapped }
    let travel = max(move, current.sizeDelta(from: previous))
    if travel >= minDistance { return .continuous }
    return .stationary
}
```

A 60pt translation at 30Hz is a fast flick; a 60pt *resize* is an edge drag.
Only translation can represent a window snapping into a tiling slot.

Upsampling is likewise driven by **distance**, not by time gap:
`interpolationSpacing = 8pt`. The first implementation interpolated by elapsed
time and emitted 59 sections for a 30-sample slow drag; `slowDragIsNotUpsampled`
now pins it at exactly 30.

## 6. Tests: 47 in 8 suites

`swift test` → `✔ Test run with 47 tests in 8 suites passed`.

Two harness lessons worth keeping:

- **Pin the render clock.** `GhostTrailRenderer.draw` takes
  `now: CFTimeInterval = CACurrentMediaTime()`. With a live clock, three
  identical renders accumulated alpha `5,263,124 → 5,201,486 → 5,157,020`
  (~0.9%) purely from render-time drift, and an equality assertion was really
  asserting on the wall clock. Tests pass `probeNow = 1_000_000`.
- **Resampling still is not bit-deterministic.** Even pinned, two renders differ
  by ~8 units of alpha out of 5.26M (0.00015%). Comparison tests use a
  tolerance of 1,000 — ~125× that noise floor and ~480× below the smallest
  genuine defect ever measured (483,860 alpha for an occluder that touched
  nothing).

`RendererRasterisationTests` rasterises through `ImageRenderer` and asserts on
*painted area* and *summed alpha over a region*, not on individual pixels: the
gradient ramps ~67→189, so any per-pixel threshold is an assertion about where
in the ramp it landed.

## 7. The live probe, and what it has and has not proven

`Examples/GhostTrailProbe` is committed on purpose. "The trail doesn't show up"
is the one bug a unit test cannot catch — it needs a real window server, a real
event tap, and real pixels.

Two facts about the library's shape that the harness encodes in its header
comments, both learned the hard way:

1. **The trailed window must be in a separate process.** GhostTrail skips
   windows owned by its own PID so the overlay never trails itself, so a
   single-process probe always reports zero trails and looks broken.
2. **The parent must spin its main run loop.** Everything is driven from a
   display link installed on `.main`; a parent that `Thread.sleep`s never runs
   the loop and no trail ever appears.

Also: `CGEvent.location` is Quartz (top-left, +y down) while `NSWindow.frame` is
Cocoa (bottom-left, +y up). Posting an event with a Cocoa point lands nowhere
near the window — the tap records the press, hit-tests nothing, and no trail
appears. `quartzPoint(fromCocoa:)` converts once.

**Proven:** `start=true fallback=false` (tap installs, Accessibility granted),
`peakTrails=1 framesWithTrail=22` (a real drag produces a real trail), and the
overlay is reported by the window server at `layer=2147483630`.

**Not proven:** that a specific ribbon pixel is visibly on screen. On this
machine the desktop is saturated — a single window covers 1710×1072pt of a
1920×1243pt display, and the largest fully-uncovered rectangle is 1920×20pt.
Because window occlusion is working, a ribbon dragged across a saturated
desktop is *correctly invisible where it passes under windows*, and the probe
cannot photograph "bare desktop" to compare against. The probe now reports its
clearance and drags anyway rather than refusing to run.

Closing that gap needs a display with real empty desktop, or a probe that
asserts the two halves numerically (signal present outside the window's
footprint, absent inside it) instead of by eye.

## 8. Deliberately outstanding

- Live pixel-level proof, per the above.
- `TrailPreset` values were retuned by eye against the new ribbon geometry, not
  measured against a reference.
- The probe's bare-desktop search (`findBareDesktopStart`) is a grid scan at
  40pt; fine for a harness, not a rectangle-packing algorithm.