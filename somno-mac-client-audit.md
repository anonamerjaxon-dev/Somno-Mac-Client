# Somno Mac Client — Thorough Audit

**Target:** `/Users/jackson/Desktop/work related/claude/somno mac client` (branch `main`, 23 commits, remote `github.com/anonamerjaxon-dev/Something-Client-Mac.git`, MIT © 2026 anonamerjaxon-dev)
**Date:** 2026-10-02 · **Method:** every Swift source file read in full per module (≈21.5K LOC excl. `.build`), all builds/tests executed, repo hygiene + git history swept. Nothing was modified; builds wrote only to `.build/` and `/tmp`.
**Raw per-finding detail (file:line everywhere):** `somno-audit-notes.md` (same folder as this report).

---

## Executive summary

**Overall: C+** — an unusually honest, well-documented body of work with **two genuinely excellent artifacts** (the black hole shader's physics, the desktop-canvas Metal/window core), undermined by systemic problems that repeat across modules:

1. **Testing is essentially absent.** 6 modules, ~zero real automated tests. Two packages print "0 tests, passed"; one package's only test target **breaks the default build**; the custom TestRunner harnesses are partially dead or can false-green. Every high-risk area (lifecycle, coordinate math, threads, Metal) is untested.
2. **Coordinate/multi-display math is wrong almost everywhere.** Primary-display-only assumptions in cursor trail, ghost trail, and desktop-canvas mean every feature misplaces or drops content on a secondary display — and one of them vertically mirrors it.
3. **Lifecycle/threading hazards are the top crash class:** self-retaining display links (unstoppable zombies), display-link teardown races, an HID callback use-after-free, full window teardown on every drag against the project's own spike warning, and two `try!`/`as!`/`Int(∞)` traps on hostile input.
4. **Docs drift from code systematically:** README examples that don't compile, features documented but not implemented (speed mode, movement threshold, coordinate conversion, snap-to-grid), scripts referenced but not committed, stale paths from another machine, and two modules whose *headline feature* is unshipped (totem animation) or contradicts its generating prompt (ghost trail renders *above* windows, not behind).

**Grades by module:**

| Module | Grade | One-line verdict |
|---|---|---|
| black hole (Ghostty shader + tuner) | **B−** | Physically correct shader, solid token decode; missing README scripts, shield gap, tuner defaults ≠ shipped values. |
| polymorph (CursorFX) | **B−** | Well-structured, all 13 private CGS symbols verified resolving; but its #1 known issue is a real code bug, Coverage feature is dead code, crash/OOM paths on CLI. |
| desktop-canvas | **C+** | Best-documented core (every prior P0/P1/P2 bug verified fixed, zero TODOs) — but default build fails, multi-display broken, drag = full teardown, zero tests. |
| cursor trail | **C+** | Clean architecture + correct ring buffer; self-retain kills cleanup, off-primary coordinate bug, teardown race, decorative test suite. |
| ghost trail | **C** | Fine on macOS 15+, but crashes on first `start()` on macOS 13/14 (the advertised floor), dead knob, non-compiling README example, renders above windows by default. |
| totem pop | **D+** | HID data path has a misaligned parse + two race/UAF hazards; the actual totem animation feature doesn't exist; no tests. |

---

## 1. Build & test verification (executed, not read)

| Package | `swift build` | Tests |
|---|---|---|
| cursor trail | ✅ | `swift test` → **"Executed 0 tests"** (false green); `swift run TestRunner` → 8 assertions pass |
| polymorph | ✅ (2 warnings in `Examples/PolymorphAgent/main.swift:35,97,106`) | `swift run TestRunner` → 78 assertions, 0 failed (but harness can false-green) |
| desktop-canvas | ❌ **FAILS** | none exist |
| ghost trail | ✅ | none exist |
| black hole/…/tuner | ✅ | none exist |
| totem pop | (build.sh, sudo-run app) | none exist |

**The desktop-canvas failure:** `Sources/DesktopCanvasTest/main.swift:2:8: error: no such module 'DesktopCanvasModel'` — the module was renamed to `DesktopCanvas` and the "test" target never updated; it also calls `DesktopCanvasModel.shared.apply(layout:)`, `CanvasLayout`→`CanvasModelLayout`, `RuleSet.presets[0]` — all Phase-5-era APIs. The library and demo products each build fine alone. `desktop-canvas/README.md:45,66` document the broken command.

**The false greens:** `cursor trail/Package.swift` compiles `Tests/CursorTrailTests/*.swift`, but those files only define free functions (`runRingBufferTests()` etc.) that **nothing ever calls** — no `XCTestCase`, no `@Test`, no entry point. Verified: `swift test` exits 0 having run nothing. Same pattern everywhere: the only tests that run are the hand-rolled `TestRunner`s, and polymorph's runs suites via `try?` with a cumulative counter, so a throwing suite still prints green.

---

## 2. Cross-cutting themes (the real findings)

### T1 — No module is meaningfully tested
Six modules, zero `.testTarget`s except cursor trail's decorative one. Untested in every module: lifecycle start/stop, coordinate conversion, threading, renderer geometry, config parsing. The spec for desktop-canvas explicitly promised a harness (Codable round-trip, RuleSet parsing, overlap math) — never built.

### T2 — Primary-display-only coordinate math (3 of 4 GUI modules)
- **cursor trail:** flips y with `NSScreen.main.frame.height` only, never subtracts screen origin (`CursorTrail.swift:103-105,170-171`) → clipped/misplaced trail on any secondary display.
- **ghost trail:** overlay sized to `NSScreen.main`, culls against `CGRect(origin: .zero, …)` (`GhostTrailRenderer.swift:41,96`) → trails on secondary displays **silently never render**; README claims a coordinate conversion that doesn't exist.
- **desktop-canvas:** global top-left coords fed straight into local contentView coords with **no y-flip** (`ScreenManager.swift:15-17,93`, `CanvasWindow.swift:127`) → canvases misplaced **and duplicated on every display**, vertically mirrored vs the physical layout; the editor preview replicates the same wrong map (`VisualLayoutView.swift:311-325`). A settings field even clamps coordinates to `≥ 0` (`CanvasSettingsView.swift:124`), forbidding placement on displays left/above the primary.

### T3 — Lifetime & thread-safety is the #1 crash class
- **cursor trail H1:** `Unmanaged.passRetained(self)` at `CursorTrail.swift:146` → `deinit { stop() }` can never run while running; a dropped instance is an **unstoppable zombie overlay**, and two instances permanently abandon the first. README's "deinit handles cleanup" is false.
- **cursor trail H3:** display-link thread `takeUnretainedValue()` vs unsynchronized `release()` (`:157`) → possible use-after-free; no main-thread precondition on `start/stop` (including an off-main `orderOut`).
- **ghost trail CRITICAL:** `displayLink as! CVDisplayLink` (`GhostTrail.swift:181`) force-casts **nil on the first `start()`** on macOS 13/14 → the advertised "macOS 13+" floor crashes immediately. The generating prompt supplied the safe `guard let` pattern; the code discarded it.
- **totem pop H1/H2:** HID callback uses an unretained context (`MotionSensorManager.swift:96`), the device is closed from the wrong thread without unscheduling or joining (`:64-72,113-117`), and `deviceRef`/`reportBuffer` are written on the sensor thread and cleared on main with **no synchronization** → use-after-free / double-open window.
- **desktop-canvas H3:** every drag `mouseUp` runs full `apply()` = stop + destroy + recreate all desktop windows and providers (`VisualLayoutView.swift:47-52`) — restarts AVPlayers from 0:00, drops the `ApplyResult` overlap error and the background color, and does exactly the repeated desktop-window create/destroy that `Spike/REPORT.md:32` warns crashes macOS 26.6.2. `refresh()` already exists and should be used.
- **polymorph H1:** the enforcement timer (`Polymorph.swift:252-263`) only *registers*; it never re-runs the activation steps (`CGSSetRegisteredCursor`, `CoreCursorSet`, scale bump) done at apply time → the system reasserts and wins. **This is the code-level root cause of the README's own known issue.**

### T4 — Traps on hostile/unvalidated input
- desktop-canvas `cellSize == 0` in a hand-edited preset JSON → `Int(Double.infinity)` traps (`DesktopCanvas.swift:35-36`, `GameOfLifeProvider.swift:205,317-318`); the README's clamp doesn't cover cellSize.
- polymorph `CGSBridge.swift:19 try!` reached unguarded from `Diagnostics.swift:24` via the `debug` CLI command; uncapped `sizes` (`CursorTheme.swift:110-113`) can request a ~200k² RGBA bitmap → OOM.
- ghost trail `fatalError` when `NSScreen.main` is nil in a library (`GhostTrailWindow.swift:36-38`); `start()` returns `true` when the link silently failed (`GhostTrail.swift:102-107`, same pattern in cursor trail `M8`).

### T5 — Documented features that don't exist / don't work
| Claim | Reality |
|---|---|
| cursor trail `speed`/`.adaptive` width (README:58) | `speedMode` written, **never read**; no velocity computation anywhere |
| cursor trail `.gradient` (README) | renders **one flat mid-blend color** (`TrailRenderer.swift:35,98`) |
| ghost trail `movementThreshold` (README:73, set by all 5 presets) | never passed to `WindowTracker` — hardcoded 1 px |
| ghost trail `.cornerRadius(8)` README example | method doesn't exist → example won't compile |
| ghost trail "coordinate conversion" (README:136) | no such code |
| desktop-canvas "Snap to grid" toggle | `targets.append(contentsOf: [])` — a **literal no-op** for moves (`SnapEngine.swift:119-121`) |
| desktop-canvas VideoProvider "aspect-locked" (README) | `.resizeAspectFill` **crops** (`VideoProvider.swift:48`) |
| desktop-canvas occlusion observer ("lesson #5") | installed while `superview.window` is nil → always returns early (`VideoProvider.swift:79`) |
| black hole README `demo-mode.sh`, `token-test.sh` | files don't exist in the repo |
| black hole tuner "Defaults" button | rewrites shader to **different** values than shipped (17 constants diverge) |
| black hole "TOKEN_LEVEL slider for every tunable" | regex requires a decimal; shipped `-1` never parses → row absent |
| totem pop design doc "Status: Approved" | **zero** `TotemPop*.swift` — the headline animation was never written |
| ghost trail "works on macOS 13+" | crashes on first `start()` on 13/14 (see T3) |

### T6 — Where the code is genuinely good (verified, not padding)
- **black hole shader physics:** `x'' = -1.5·h²·x/r⁵` is the exact Schwarzschild null-geodesic Binet form; leapfrog integrator, correct `B_CRIT = 3√3/2`, ISCO, exhaustive division guards (no NaN paths found), 16-bit checksum token decode matching the tuner's encoder exactly, sRGB fallback + glide verified against README.
- **desktop-canvas core:** every P0/P1/P2 bug from the review plan verified fixed in code; window level, `order(.below, relativeTo: 0)` and collectionBehavior exactly spike-faithful; Metal compute ping-pong sim correct; zero TODO/FIXME/HACK comments; main-thread serialization traced clean.
- **polymorph:** clean separation (CGSBridge/registry/themes/agent/CLI), all 13 private symbols verified resolving on macOS 26.6.2, bundled ibeam.svg loads, CLI has no shell injection.
- **cursor trail:** correct `RingBuffer` (all edge cases traced), correct click-through overlay window config, idempotent start/stop, no unintended retain cycles.

---

## 3. Repository hygiene (top items)

- **HIGH — unlicensed vendored code:** `totem pop/TransparentVideoPlayer-master/` has **no LICENSE/attribution** (2-line README, no source URL). Root MIT and black hole's vendored MIT/Bruneton credit are fine.
- **`.gitignore` gaps:** no media globs (`*.mp4 *.webm *.mov *.gif`), `.trae/` tracked but not ignored, `.vscode/` ignored **yet `.vscode/launch.json` is tracked** (contradiction).
- **Tracked junk (~16.4 MiB total):** `totem pop/this video is not it.webm` (2.3M) + `this video is not cleared.mp4` (1.9M) — junk-named media; 446 loose objects, **nothing packed**; untracked `_inspect.py` (one-off `.git/objects` dumper) left at root; `cursor trail/build.sh` hardcodes a nonexistent five-space path (`/Users/jackson/Desktop/     /claude/something client mac/…`).
- **Stale paths everywhere:** `.trae/rules/project_rules.md` (title "DesktoCanvas" [sic], refs nonexistent `something client mac/`, `somno/`, `user/`), `.vscode/launch.json` (all 20 configs use `${workspaceFolder:something client mac}`), totem pop `HOW_TO_USE.txt` (`/Users/jackson/Desktop/test`), design docs with five-space paths.
- **Root README:** omits `desktop-canvas/` and `ghost trail/` entirely (both are real packages); "each module has tests" is false (2 of 6); Planned table stale (all three planned features shipped under different names); code snippets otherwise verified accurate.
- **Docs sprawl:** 16 docs/superpowers files, incl. 6 spent agent-prompt artifacts (~130KB), two conflicting phase-numbering schemes in desktop-canvas, a "Phase 12: Tests" that never happened, and a 44KB totem pop plan/spec describing a `Sources/TotemPop/` package that doesn't exist.
- **Git history:** 4 duplicate-message consecutive pairs (different patches — rework, not dupes), two root commits merged, nested-repo history clean (commit message misleading but no `160000` gitlinks ever), remote still `Something-Client-Mac.git`, no secrets found tree-wide (`black hole/.../claude-token.py` is a statusLine bridge, no credentials).

---

## 4. Prioritized fix order

**P0 — crashes / broken build**
1. desktop-canvas: fix or delete `Sources/DesktopCanvasTest/main.swift` (restores default `swift build`), then add real test targets.
2. ghost trail: `as!` → `guard let … as?` in `GhostTrail.swift:181` (+ conditional release of `displayLinkUserInfo`) — un-breaks the advertised macOS 13+ floor.
3. totem pop: serialize HID start/stop, unschedule + join the sensor thread, fix the byte-6 XYZ parse (verify against hardware).
4. desktop-canvas: clamp `cellSize ≥ 2` in `GameOfLifeConfig` decode/init; replace `try!` Metal init with `ApplyResult` errors (polymorph: guard `CGSBridge` in `Diagnostics`).
5. desktop-canvas: use `refresh(with:)` instead of full `apply()` in the drag commit path; carry `backgroundColor`; surface `ApplyResult`.

**P1 — correctness**
6. Coordinate overhauls: cursor trail (origin + y-flip), ghost trail (overlay-local conversion, span all screens), desktop-canvas (per-screen filtering + origin + y-flip, both library and preview; lift the `≥0` clamp).
7. cursor trail: replace `passRetained` with explicit lifetime + `current === self` guard; synchronize display-link teardown; main-thread preconditions.
8. polymorph: make the enforcement timer repeat activation (`CoreCursorSet`/scale bump), wire `installMouseMonitors()`, fix the fallback skin path.

**P2 — truth in advertising**
9. Either implement or delete: cursor trail speed/gradient, ghost trail `movementThreshold`/`cornerRadius` example, desktop-canvas snap-to-grid toggle, occlusion observer, black hole scripts; make tuner "Defaults" snapshot the parsed file.
10. Root README: add the two missing modules, fix "each module has tests", refresh Planned table; purge stale five-space paths from `.trae/`, `.vscode/`, build scripts.
11. Remove tracked junk media + `_inspect.py`; add media `.gitignore` globs; **resolve the TransparentVideoPlayer license**; `git gc --aggressive` (446 loose objects).

**P3 — quality of life:** 30 Hz throttle on `CGWindowListCopyWindowInfo`; per-frame allocation cuts in `TrailRenderer`; grid-bitmap rebuild only on generation change; background `ps` spawns in the tuner; wire the dead test harness entry points so `swift test` means something.
