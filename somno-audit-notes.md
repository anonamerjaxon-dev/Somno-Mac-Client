# Somno Mac Client — audit working notes (raw findings)

Project: `/Users/jackson/Desktop/work related/claude/somno mac client`

## Build/test verification (ran 2026-10-02)

- `cursor trail`: `swift build` OK; `swift test` → "Executed 0 tests" (FALSE GREEN); `swift run TestRunner` → RingBuffer suite 8 assertions pass.
- `polymorph`: `swift build` OK (warnings in Examples/PolymorphAgent/main.swift:35 unused try?, :97/:106/:106 confusable trailing closures); `swift run TestRunner` → 78 assertions 0 failed (but see stats bug).
- `desktop-canvas`: `swift build` FAILS (exit 1):
  `desktop-canvas/Sources/DesktopCanvasTest/main.swift:2:8: error: no such module 'DesktopCanvasModel'` — stale module name (real module is `DesktopCanvas`); file also calls `DesktopCanvasModel.shared.apply(layout:)`, `CanvasModel`, `GameOfLifeConfig`, `RuleSet.presets[0]` (Phase 5 era API). Library target `DesktopCanvas` and `DesktopCanvasDemo` each build fine individually.
  `desktop-canvas/README.md:45,66` documents `swift run DesktopCanvasTest` → documented command does not build.
- `ghost trail`: build OK clean. `black hole/.../tuner`: build OK clean.

## Repo hygiene (subagent-verified)

.gitignore root covers .DS_Store/.build//DerivedData/xcuserdata/.swiftpm etc.
- MISSING: media globs (*.mp4 *.webm *.mov *.gif), `.trae/`, `build-output.txt`, `.firecrawl/`.
- CONTRADICTION: `.vscode/` ignored at .gitignore:33 yet `.vscode/launch.json` tracked; `.trae/` tracked but not ignored.
- Clean: no .build/.DS_Store/DerivedData/Xcode sidecars tracked. git status = 1 untracked line `_inspect.py`.
- Tracked: 161 files, ~16.4 MiB, 446 loose objects (0 packed). Media: black hole demo.gif 7.6M + presets-grid.png 3.0M (vendored), `totem pop/this video is not it.webm` 2.3M + `totem pop/this video is not cleared.mp4` 1.9M (junk-named, commit 0934588), playdoh-bat.mp4 288K.
- `_inspect.py` (untracked, 54 lines): one-off forensic script, reads HEAD commit f386dd4 out of .git/objects via zlib, dumps root tree + 1 subtree to `_commit.txt` (absent). Junk — delete.
- `.trae/rules/project_rules.md` (tracked): title "# DesktoCanvas — Agent Guidelines" [sic]; :118 build cmd uses nonexistent `.../claude/something client mac/desktop-canvas`; :139-149 structure claims `something client mac/`, `somno/`, `user/` — all verified nonexistent.
- `.vscode/launch.json` (tracked): all 20 configs use `${workspaceFolder:something client mac}` → all broken; also refs `totem pop/.worktrees/totempop`.
- Root README: Modules + Project Structure (L71-77) list only cursor trail/polymorph/totem pop/black hole — `desktop-canvas/` and `ghost trail/` MISSING entirely (both have Package.swift + README). Planned table L59-66 stale: Moving Wallpaper + Fun Wallpapers = desktop-canvas VideoProvider/GameOfLifeProvider; Window Drag Trail = ghost trail. L80 "each module has tests" false (only 2 of 6). Dev commands OK; code snippets verified to exist (CursorTrail() init:25, .color:31, .style:74, .start:100; CursorTheme.load:43, Polymorph.apply:53). Known-issue L35 accurate. Architecture notes L97-100 all verified.
- `cursor trail/build.sh` (tracked, mode 644): L3/L5 hardcode five-space nonexistent path `/Users/jackson/Desktop/     /claude/something client mac/cursor trail` — dead.
- LICENSE root MIT © 2026 anonamerjaxon-dev OK; black hole vendored has own MIT LICENSE (s13k) + Bruneton credit OK; **`totem pop/TransparentVideoPlayer-master/` has NO LICENSE/attribution (HIGH)** — README.md 2 lines, no author/source URL.
- Git: 23 commits, 4 duplicate-message consecutive pairs (44e173d/9b0aa73 Phase 10, 7b7866e/afb1cfa Phase 8, e7a6691/5320243 v0.3.0, 0009c53/c112144 docs) — different patch-ids = rework not dupes. Two root commits ddb9b0c + fdbe89a merged 7cb54aa. No 160000 gitlinks ever; nested repo never committed (commit 4255088 message misleading but history clean). Remote still `Something-Client-Mac.git`.
- Docs sprawl 16 files: desktop-canvas 10 (plans mark only Phase 1 + Phase 5 DONE though Phases 8-11 shipped; two conflicting phase schemes Phase 6-14 vs "Revised Phase 6-12"; filename 09-12 vs body date 09-13; 6 spent agent-prompt artifacts ~130KB; Phase 12 "Tests" never done), totem pop 2 (44KB plan/spec describe `Sources/TotemPop/` package that doesn't exist), cursor trail 2 (matches shipped), polymorph 2, black hole 0, ghost trail 0.
- Secrets: none found tree-wide. `black hole/.../claude-token.py` looks scary, is a Claude statusLine→OSC-12 bridge, no credentials.

## Polymorph audit (subagent, grade B−)

2,022 Swift LOC; library 1,096 LOC/8 files. CGSBridge dlopen+dlsym 13 private CGS symbols from CoreGraphics/ApplicationServices/SkyLight (no hardcoded offsets). Verified: build + TestRunner 78 assertions pass, all 13 symbols resolve on macOS 26.6.2, bundled ibeam.svg loads via AppKit SVG decoder.
- **H1 enforcement register-only**: `Polymorph.swift:252-263` timer tick only calls registerCursorWithImages; activation steps done at apply time (`CGSSetRegisteredCursor` Polymorph.swift:136-139, `CoreCursorSet` :140-144, scale-bump refresh) never repeated → cannot win against system reassert. THIS is the code-level cause of README known issue. `reassert()` :221-228 only re-activates arrow name.
- **H2 agent coverage dead code**: `installMouseMonitors()` PolymorphAgent/main.swift:91-111 never called → click/move reassert handlers + Coverage menu (:157-166, UserDefaults :341) do nothing. `applyToFrontmost` (:289-338) no selector wiring = dead (it's the README's own per-connection fix idea; plumbing `connectionID(forWindowNumber:)` Polymorph.swift:86-92 + `apply(theme:cid:refresh:)` :60-84 exists). No `AXIsProcessTrusted` anywhere.
- **H3 wrong fallback skin path**: PolymorphAgent/main.swift:23-25 `~/Desktop/work related/claude/something client mac/polymorph/Examples/Skins/Tuff` — nonexistent → fresh install loads no skin.
- M1 crash path: `CGSBridge.swift:19 static let shared = try! CGSBridge()`; unguarded use `Diagnostics.swift:24` ← runDiagnostics :77 ← CLI debug PolymorphCLI/main.swift:10.
- M2 unbounded rasterization: CursorTheme.swift:110-113 `sizes` uncapped → ThemeImageLoader.swift:50-61 NSBitmapImageRep at size×2 (theme.json "arrow":100000 ⇒ ~200k² RGBA bitmap → OOM).
- M3 errors are CustomStringConvertible not LocalizedError → `localizedDescription` sites (Polymorph.swift:27, Demo:113/130/140/153/164, Agent:217/324) print generic "The operation couldn't be completed…". Verified repro.
- M4 no thread safety: statics Polymorph.swift:230-233 unsynchronized; AppKit/CG work (ThemeImageLoader.rasterize mutates NSGraphicsContext.current ThemeImageLoader.swift:64-92) with no main-thread precondition.
- M5 tests can false-green: suites run `try? testX()` TestRunner/main.swift:193-201; runSuite :57 uses cumulative global counter so per-suite numbers misleading; tempRoot never deleted.
- L: stopEnforcement doesn't clear enforcedRegistrations (Polymorph.swift:233 vs 269-274) retains CGImages; StockCapture.swift:45-46 `unsafeBitCast(value, to: CGImage.self)` no CFGetTypeID; StockCapture.swift:86 manifest path traversal; frameCount hardcoded 1 with N-image arrays (StockCapture:117, Polymorph:127-130); CursorTheme.swift:78-79 double-scan force unwrap TOCTOU; Diagnostics.swift:44 dumps slots 0...24 vs maxCoreCursorSlot 43 (Polymorph.swift:150); agent logs to /tmp/polymorph-agent.log (Agent:33-42); `show(arrow:)` ignores param (Polymorph.swift:94-97); DisplayChangeMonitor Unmanaged.passUnretained race (DisplayChangeMonitor.swift:35,42); relaunchApp busy-waits main thread up to 8s (Agent:355-359); NSMenuItem.isEnabled overridden by autoenablesItems.
- CLI: hand-rolled switch, no shell, tilde expanded (PolymorphCLI:8,31); `capture`/`restore` don't validate arg count; `debug` applies then RESTORES at end (Diagnostics.swift:114, undocumented) + Thread.sleep 15s (:96-97).
- Docs: README:118 example uses `~/Skins/tuff` but library never expands `~`; README omits PolymorphCLI/PolymorphAgent; spec:97-98 claims hotspot→CGS coordinate conversion that doesn't exist (CursorTheme.resolveHotspot :124-132 raw point passed through Polymorph.swift:126); spec:62 `DemoUI.swift` + :65 `Tests/PolymorphTests/` don't exist; spec:105 2x warning not implemented; spec:146 "Every CGS call checked" false (_ = discards at Polymorph:138,143,163; enforcement ignores errors :255-261).

## Cursor trail audit (subagent, grade C+)

601 LOC Sources (10 files), 144 Tests, 84 TestRunner, 316 demo = 1,145 LOC. CursorTrail builder + CVDisplayLink (callback hops main, polls NSEvent.mouseLocation, RingBuffer, idle fade) → TrailWindow (.screenSaver, ignoresMouseEvents, canJoinAllSpaces/fullScreenAuxiliary, NSHostingController→Canvas) → TrailRenderer (line = 4-pass stroke, ribbon = Catmull-Rom + normals, optional blur glow).
- **H1 self-retain kills deinit**: CursorTrail.swift:146 `Unmanaged.passRetained(self)` as display-link userInfo (released :157) → deinit { stop() } :19-21 unreachable while running; started+dropped instance leaks forever with live link + overlay; two instances: `A.start(); B.start()` sets `current = B` (:114) abandoning A permanently (self-retained, unstoppable overlay); `stop()` nils `current` unconditionally (:126). README:175 "deinit handles cleanup" false. Fix: passUnretained + nil `current` only if `current === self`.
- **H2 coordinate math ignores screen origin**: CursorTrail.swift:103-105/:170-171 `screenHeight = NSScreen.main?.frame.height`, `location.y = screenHeight - location.y`, x raw; TrailWindow.swift:26-28 window at `screen.frame`. Needs local = global − screen.frame.origin with y-flip about maxY. Breaks on secondary display (origin 2560,0 → clipped; stacked display → 1440 offset). README:172 "only main display" vs code uses NSScreen.main (key-window screen).
- **H3 display-link teardown race**: callback on CVDisplayLink thread :134-141 takeUnretainedValue; stopDisplayLink :152-159 CVDisplayLinkStop then immediate `release()` :157 — not documented to drain in-flight callback → possible use-after-free. No thread confinement: start/stop/updateTrail mutate shared state from any thread; `trailWindow?.orderOut(nil)` :122 off-main AppKit call.
- **H4 tests decorative**: verified `swift test` = 0 tests. Tests/CursorTrailTests free functions (runRingBufferTests RingBufferTests.swift:38, runTrailConfigurationTests TrailConfigurationTests.swift:29, runCursorTrailTests CursorTrailTests.swift:8) have NO caller anywhere; no XCTestCase/@Test; custom harness TestUtilities.swift:6-57 (runTestSuite fatalError) dead. Only TestRunner/main.swift:76-81 (4 RingBuffer tests) runs. Untested: lifecycle, display link, coordinate flip, idle fade, renderer geometry, window config.
- M1 `.gradient` renders flat mid color: TrailRenderer.swift:35/:98 pick ONE color at count/2 for whole path; trailColor gradient case :181-183; glow uses index 0 (:106) so glow≠trail color.
- M2 dead code advertised: `speedMode` written (CursorTrail:80-83, TrailConfiguration:12/25/37), never read — no velocity computation; TrailPoint.timestamp set never read; README:58 documents speed/.adaptive, README:155 + CLAUDE.md:29 claim TrailPoint has velocity (no field).
- M3 multi-instance contradicts spec docs/.../2026-06-28-cursor-trail-design.md:167 ("second start() returns false"); guard CursorTrail.swift:101 is per-instance only → both instances run (worsened by H1).
- M4 no display reconfiguration handling: screenHeight CursorTrail:103 + window frame TrailWindow:26-28 snapshot once at start(); no didChangeScreenParametersNotification observer.
- M5 `.line` never tapers: TrailRenderer.swift:36 one thickness for whole stroke, 4 passes :39-49 uniform; taper only in ribbon :73; TrailConfiguration.swift:43 `if !diminishing { return forLine ? 0.2 : 1.0 }` → diminishing:false still renders 4 widths; ribbon tapers thin-at-tail so README:55 wording backwards.
- M6 per-frame allocations: TrailRenderer.swift:63-69/:131-153 rebuilds smoothPoints + edges arrays every frame (~1,193 samples at length 150); :191-199 NSColor→sRGB per frame; :109-115 gaussian .blur over fullscreen canvas per frame; CursorTrail.swift:191 + TrailWindow.swift:36 model.trailPoints shares ring buffer storage → next append RingBuffer.swift:23-31 clones array O(n) per frame.
- M7 build.sh broken (five-space stale path, see hygiene).
- M8 start() ignores CVReturn: CursorTrail.swift:143-149 CVDisplayLinkCreate/SetOutput/Start results ignored; on failure silently returns but start() sets isRunning=true, returns true (:113-115).
- L: README:169 double-start claim wrong (same instance returns false :101); README:6 demo.gif missing; `.length()` post-start reallocates trailPoints (CursorTrail:43-47) while other builders no-op; idle frames reassign @Published trailPoints → re-render (CursorTrail:181-192, TrailWindow:36); TrailRenderer.swift:6 `yOffset = 16` magic shift; fade per-frame → 2× faster on 120Hz (CursorTrail:182-187); collectionBehavior missing .transient/.ignoresCycle (TrailWindow:24); CLAUDE.md drift (:29 velocity, :41 TestRunner description, :45 wrong Y-flip location, :47 `colorForTrail()` doesn't exist); no CursorTrail(configuration:) init; demo slider 1...50 vs clamp max(length,10) (Demo main.swift:174 vs CursorTrail:44); README:161 "live-tuning" overstated; CursorTrail.current public unsynchronized static; RingBuffer.clear() reallocates (RingBuffer.swift:44); demo TrailController not final.
- Verified-good: RingBuffer logic correct all cases; start/stop idempotent; no retain cycles besides passRetained ([weak trail] at :137); window config correct (TrailWindow:19-24); Catmull-Rom + normals edge-safe (TrailRenderer:13,55,71-86,138-150); README defaults table matches code except noted rows.

## desktop-canvas audit (subagent, grade C+)

SCOPE: 12 library files (1,529 LOC), 10 demo files (3,304 LOC), DesktopCanvasTest/main.swift, Package.swift, README, Spike/REPORT.md, design spec 2026-09-12, review-and-forward-plan. grep TODO/FIXME/HACK = ZERO. Builds into /tmp/dc-audit-build.
BUILD: default `swift build` FAILS (import DesktopCanvasModel, real module DesktopCanvas; also uses nonexistent CanvasModelLayout/DesktopCanvas.shared APIs — actual type `CanvasLayout`, test never updated after API rename). `swift build --product DesktopCanvasDemo` SUCCEEDS. ColorWell.swift:36-39 redeclares CodableColor.nsColor — compiles, drop as bug (shadowing smell only).

CRITICAL
C1. Sources/DesktopCanvasTest/main.swift:2 import stale module → whole-package default build + README `swift run DesktopCanvasTest` broken. NO .testTarget in Package.swift, NO tests anywhere; spec:75-77,:303-305 promised harness (Codable round-trip, RuleSet parsing, BrushTool, overlap math, double-buffering).

HIGH
H1 MULTI-DISPLAY BROKEN: ScreenManager.swift:15-17 + :93 layoutCanvases for EVERY screen + CanvasWindow.swift:127 renderer.frame = canvas.frame — global top-left coords used as local contentView coords; no per-screen filtering/origin translation → wrong place + duplicated on every display (each runs full sim copy). Works only because primary origin (0,0).
H2 VERTICAL MIRROR: same + VisualLayoutView.swift:311-325 scaledRect/viewToScreen identical unflipped map → global y-down into y-up AppKit; preview self-consistent with desktop but inverted vs physical (menu bar/dock side). Fix: offsetBy(-screen.frame.origin) + flip (screen.frame.maxY - y - h) in both library and editor preview.
H3 DRAG = FULL TEARDOWN: VisualLayoutView.swift:47-52 Coordinator.commit() calls DesktopCanvas.shared.apply(layout:) on EVERY mouseUp → apply→stop (DesktopCanvas.swift:40,54-57 orderOut + release all windows) → new ScreenManager → new windows. (a) AVPlayers restart 0:00 each drag; (b) repeated create/destroy desktop-level NSWindows = the macOS 26.6.2 autorelease-pool crash spike warned about (Spike/REPORT.md:32,:109 "production creates ONE persistent window… never destroys it"); (c) IGNORES ApplyResult — apply REJECTS overlapping layouts with .error (DesktopCanvas.swift:25-29) → editor/desktop silently diverge after overlapping drag; (d) layout built WITHOUT backgroundColor → any drag CLEARS desktop background color. Fix: use existing `refresh(with:)` (ScreenManager.swift:81-87) for frame-only moves, carry backgroundColor, surface errors.
H4 cellSize==0 CRASH: unclamped GameOfLifeConfig (synthesized Codable Canvas.swift:9-40; spec:149 min cell 2 not enforced): DesktopCanvas.swift:35-36 `Int(floor(frame.width / CGFloat(config.cellSize)))` → Int(Double.infinity) traps; GameOfLifeProvider.swift:205 setupGrid + :317-318 update same division; EditorState.swift:218-223 fillScreen → NaN/∞. Slider can't do 0 (2...64) but hand-edited/corrupt preset JSON crashes. README's clamp (Canvas.swift:107-121) only covers CGRect 4-value + ≥32 size, NOT cellSize.
H5 SNAP-TO-GRID DEAD FOR MOVES: SnapEngine.swift:119-121 `if snapToGrid { targets.append(contentsOf: []) }` literal no-op → snapEdgePoint/snapRect never grid-snap; grid snap only in snapCornerResize (:201-204); toolbar Toggle (EditorView.swift:118-122) does nothing during moves.
H6 PAUSE DESYNC (3 sources: config.paused / provider timer / editor isPlaying): GameOfLifeProvider.swift:339-344 resume() ignores config.paused → ScreenManager.swift:47 wake resumeAllProviders() un-pauses user-paused sim; GridEditorView.swift:435-446 flushAndResume `if !wasPlaying { provider.resume() }` un-pauses on editor close; isPlaying starts false (:135), loadGridState (:372-412) pauses without initing isPlaying from config.paused.

MEDIUM
M1 occlusion observer never installed: VideoProvider.swift:79 `guard let window = superview.window else { return }` — attach called from CanvasRenderer.init (CanvasRenderer.swift:10) before addSubview (CanvasWindow.swift:134) → always returns early → README lesson #5 space-aware play/pause dead.
M2 screen change stale frames: ScreenManager.swift:97-112 handleScreenChange only removes/adds; surviving windows never reframed; dict keyed NSScreen identity (:4) → identity-dependent churn.
M3 bg color live-edit no-op: setBackgroundColor only in createWindow (ScreenManager.swift:92); refresh (:81-87) never applies backgroundColor.
M4 library imposes app policy: ScreenManager.swift:13 NSApplication.shared.setActivationPolicy(.accessory) inside applyEmbedded — hides demo from Dock.
M5 grid editor full-bitmap rebuild per SwiftUI update: GridEditorView.swift:577-595 updateNSView assigns nsView.grid unconditionally → didSet (:618-620) bumps generation → rebuildGridBitmap (:741-789) rasterizes whole grid on every hover mouseMoved (:963-975).
M6 preset list decodes all JSON every body eval: EditorState.swift:24-26 → DesktopCanvas.listPresetsWithMetadata (DesktopCanvas.swift:96-113) loads every preset per view update.
M7 Metal init try!: GameOfLifeProvider.swift:160-171 device.makeLibrary/makeComputePipelineState/makeRenderPipelineState force-try; spec:299 device-loss reinit not implemented; :567 Float(drawableSize.width / bounds.width) NaN if bounds.width==0.
M8 spike divergence: Spike REPORT:47,:116-118 prescribe isPaused=false, enableSetNeedsDisplay=false, MTKViewDelegate.draw(in:) ("NSView.draw(_:) no-op for MTKView"); production sets NEITHER flag (grep zero), overrides draw(_:) with nil delegate, justified only by comment GameOfLifeProvider.swift:523-526. REPORT:83 inline-strings-vs-metal accepted by review doc:23.
M9 key-eater: GridEditorView.swift:155-181 local key monitor consumes Space/P/L/R/G app-wide while sheet open (removed correctly :184-186).
M10 spec features absent: live overlap prevention + red flash (spec:145-146,:270-279) — OverlapResolver.resolve (:18-53) + validate (:66-71) DEAD CODE, only detectOverlaps used at DesktopCanvas.swift:25; Live Overlay Mode (spec:190-194) no matches; custom B3/S23 text field (spec:140,:169) — CanvasSettingsView:207-223 preset Picker only; lastAppliedPreset UserDefaults key (spec:287) absent (concern #5 open).
M11 positive-field clamp: CanvasSettingsView.swift:124 `onChange(max(0, $0))` forbids negative X/Y — can't position on display left/above primary.

LOW
L1 SnapEngine snap()/snapOrigin() (:15-23) never called; snapCornerResize :240-244 overwrites snapped size w/o re-anchoring origin → opposite edge jumps; snapSize ÷cellSize (÷0 risk); hardcoded guide threshold 1.0 VisualLayoutView:427 vs snapThreshold 6 → guides almost never render.
L2 VisualLayoutView force unwrap cachedScreens.first! :123; freeCornerResize :375-417 NEGATIVE height possible (no min-size on y, bypasses 32pt clamp via direct frame mutation :144/:152/:157).
L3 GridEditorView dead code: handleCellAction :463-469, placePattern :494-513, onCellAction param :558 + Coordinator slot :598 never wired; line/rect fills implemented twice (local NSView :933-957 AND provider handleShapeComplete :471-492); `.pencil,.eraser: break` :487-488 dead.
L4 VideoProvider.swift:48 videoGravity .resizeAspectFill CROPS — README claims aspect-locked (should be .resizeAspect); :52 statusObserver [.new] misses already-.failed. Phase-11 zero-frame fix present/correct (:27-30,:47,:75,:151-154).
L5 observer-leak edge: NotificationCenter blocks (GoL powerStateObserver :186-193 removed only in detach :295-298; same for VideoProvider) leak if provider released before renderer — CanvasRenderer.provider weak (CanvasRenderer.swift:4) so deinit detach no-ops; order-dependent.
L6 DesktopCanvas.swift:119 .first! force unwrap (presetsDirectory); CanvasModel.== id-only (Canvas.swift:70-72) → onChange blind to content edits.
L7 no per-frame autoreleasepool/completion handlers/GPU-blit realloc (plan concern #6 accepted defer).
L8 repeated full-apply writes _last_used.json every mouseUp (DesktopCanvas.swift:46).

KNOWN-ISSUES CHECK (review-and-forward-plan :1192-1204): P0 NSApp terminate FIXED; P0 overlap detect FIXED (DesktopCanvas:25); P1 JSON ≥32 clamp FIXED (Canvas.swift:107-121); P1 ApplyResult warning FIXED (:3-7,:48-50); P1 timer-at-attach FIXED (GameOfLifeProvider:291); P1 clipsToBounds FIXED (CanvasRenderer:19-21); P2 isTimerRunning FIXED (:112,:244-284,:333-342 traced balanced); P2 loopObserver strong-player FIXED (VideoProvider:67); P2 GPU blit not done (documented acceptable); P3 auto-save-every-apply NOT changed (still :46, spec-compliant); P3 double-wrap CanvasRenderer unchanged (deferred). README Phase-11 claims verified: NSApp lifecycle ✓ timer ✓ JSON clamp ✓ clipsToBounds ✓ cell-cap→ApplyResult ✓ (but H4 cellSize still unclamped) zero-frame ✓.

ARCHITECTURE: library DesktopCanvas (facade/ApplyResult/presets) → ScreenManager (1 NSScreen → 1 borderless CanvasWindow at CGWindowLevelForKey(.desktopIconWindow), collectionBehavior .canJoinAllSpaces/.stationary/.transient/.ignoresCycle/.fullScreenAuxiliary, order(.below, relativeTo: 0) CanvasWindow:16-40 — spike-faithful) → CanvasRenderer (NSView shell) hosting GameOfLifeProvider (MTKView, Metal compute ping-pong B/S bitmask, storageModeShared, framebufferOnly=false, 30/60fps power-aware timer, draw-override) or VideoProvider (AVPlayer/AVPlayerLayer, loop actionAtItemEnd=.none + seek-zero, placeholder, deferred play). Demo: EditorState single source of layout, debounced auto-apply, grid round-trip via preset JSON; GoL timer dispatches setNeedsDisplay to main → serialize on main, no cross-thread mutation found. Demo 3,304 LOC; GridEditorView 1,103 LOC (does too much). Presets JSON ~/Library/Application Support/DesktopCanvas/presets/. Coverage: Metal 8/10, window mgmt 6/10, GoL 7/10, Video 7/10, demo 5/10, tests 1/10, docs-vs-code 7/10. Fix order: C1 → H3 → H4 → H1/H2 → H5/H6 → M1-M6.

## ghost trail audit (subagent, grade C)

Library (builder API, ring buffer, overlay window, display-link), no Tests/ dir, no test target.
- [CRITICAL] GhostTrail.swift:181 `let link = displayLink as! CVDisplayLink` in stopLegacyDisplayLink(): start() → startDisplayLink() :100 → first stmt stopDisplayLink() :127 → macOS 13/14 #available(macOS 15.0,*) :170 false → stopLegacyDisplayLink() :175 → displayLink nil on FIRST start → as! traps. Also fires on stop-then-deinit and deinit of never-started instance (deinit :17-20 calls stopDisplayLink() unconditionally). ⇒ macOS 13/14 crashes on first start(); README.md:5 "macOS 13+" and Package.swift:6 .v13 false. PROMPT.md:54 handed safe pattern `guard let link = displayLink else { return }` — discarded. Fix: `guard let link = displayLink as? CVDisplayLink else { return }`, only release displayLinkUserInfo when link existed.
- [HIGH] Trail renders ABOVE dragged window — GhostTrailConfiguration.swift:30 default windowLevel `.aboveWindows` → GhostTrailWindow.swift:29-31 maps to .floating; PROMPT.md:7 "behind the window (never covering…)", PROMPT.md:110-112 always behind, PROMPT.md:92 .screenSaver. Overlay (GhostTrailWindow.swift:39, ignoresMouseEvents :26) draws over everything. README.md:15,:78 document drifted behavior. Fix: default .behindWindows (mapping exists :33).
- [MEDIUM, latent behind critical] GhostTrail.swift:162 Unmanaged.passRetained(self) in startLegacyDisplayLink — dropped-without-stop instance never deinits → permanent leak, link+window run forever.
- [MEDIUM] movementThreshold dead: builder GhostTrail.swift:53-54, field GhostTrailConfiguration.swift:13/25/36, all 5 presets set it (:49,:59,:71,:81,:93); WindowTracker constructed with only frameCount/fadeDuration (GhostTrail.swift:90-93), detection hardcoded `} else if dx > 0 || dy > 0 {` (WindowTracker.swift:53,:104). README.md:73 documents it; PROMPT.md:286 asked for it. Always 1px.
- [MEDIUM] README.md:51 example `.cornerRadius(8)` — no such builder (GhostTrail.swift:29-80); cornerRadius only config field (GhostTrailConfiguration.swift:17). Example doesn't compile.
- [MEDIUM] Multi-display trails never render: GhostTrailWindow.swift:36-41 overlay sized NSScreen.main only; window frames in CG global (WindowTracker.swift:43) culled unless intersect CGRect(origin:.zero,size:size) (GhostTrailRenderer.swift:41,:96) → secondary-display windows dropped every frame. PROMPT.md:294,:326 flagged, unaddressed.
- [MEDIUM] README.md:136 claims coordinate conversion CG top-left→AppKit via NSScreen.main.frame.height — no such code exists (full read); PROMPT.md:131-134 specified it. Accidentally right only on main display.
- [MEDIUM] Unthrottled polling: GhostTrail.swift:192-197 tracker.poll() every display-link frame (60-120Hz) → CGWindowListCopyWindowInfo system-wide each time (WindowTracker.swift:22); PROMPT.md:366-369 asked 30Hz throttle — none.
- [MEDIUM] .solid ignores opacity: layer alphas hardcoded GhostTrailRenderer.swift:77-82 (1.0,0.06)(0.65,0.12)(0.35,0.20)(0.15,0.30); baseOpacity only visibility gate >0.01 (:94,:113) → .opacity() no effect in .solid though dramatic/neon/glass presets set it (GhostTrailConfiguration.swift:60,:82,:94, README.md:102-105).
- [MEDIUM] deinit clobbers static: GhostTrail.swift:17-20 `deinit { GhostTrail.current = nil; ... }` unconditional → never-started temp release nils RUNNING instance's GhostTrail.current (:7), breaking GhostTrail.current?.stop() (README:37). stop() guards correctly (:119-121).
- [LOW] .filled opacity applied twice: GhostTrailRenderer.swift:38 color opacity(opacity) then :57 fill color.opacity(opacity*0.3) → fill alpha = opacity²×0.3.
- [LOW] GhostTrail.swift:133-136 guard NSScreen.main nil → returns leaving displayLink nil but start() still isRunning=true, returns true (:102-107) → window shown, nothing renders, never retried.
- [LOW] GhostTrailWindow.swift:36-38 fatalError if NSScreen.main nil (PROMPT.md:95-97 used non-fatal if-let).
- [LOW] collectionBehavior [.canJoinAllSpaces,.stationary] (GhostTrailWindow.swift:27) vs PROMPT.md:93 [.canJoinAllSpaces,.fullScreenAuxiliary] → no trail over fullscreen apps; spec drift.
- [LOW] README.md:10 "frames shrink at constant rate" — only opacity fades (GhostTrailRenderer.swift:162-167).
- [LOW] Demo Examples/GhostTrailDemo/main.swift:25 isRunning = start(); restartWith preset (:54-58) then Stop→Start reverts to original default config; start()==false desyncs menu (:26-27 vs :21).
- [LOW] WindowTracker.swift:49 `jumped = dx > 200 || dy > 200` hardcoded, not configurable.
- INFO: single-trail policy by design — poll deletes other windows' trails each frame (WindowTracker.swift:73-80); README:11 "One trail at a time".
- Verified good: ring buffer logic correct.

## totem pop audit (subagent, grade D+)

Structure: `test/` = sudo-run SwiftUI viewer for BMI286 IMU (3 files + build.sh); design doc's TotemPop package entirely unimplemented. No tests.
- [HIGH] UAF risk in HID lifecycle: MotionSensorManager.swift:96 Unmanaged.passUnretained(self), callback takeUnretainedValue() :100; deinit→stop() :46-48 any thread; stop() :64-72 calls IOHIDDeviceClose from MAIN while device scheduled on SENSOR thread run loop (:113-117), never IOHIDDeviceUnscheduleFromRunLoop, never joins thread (sensorThread?.cancel() :65-66) → in-flight callback can fire after close/dealloc. start() after stop() passes guard :53 (sensorThread nilled) → can double-open while old thread exits.
- [HIGH] Unsynchronized cross-thread state: deviceRef=device :89 and reportBuffer=buffer :93 written on sensor thread, read/cleared in stop() on main :67-71; sensorThread read :125 vs main writes :60/:66. No locks/atomics.
- [HIGH] XYZ parse misaligned: imuDataOffset=6 comment :30 "XYZ payload starts here", but `ptr[imuDataOffset/4]`=ptr[1] → bytes 4-7 (:196), ptr[2] bytes 8-11 (:199), ptr[3] bytes 12-15 (:202) — integer division truncates, nothing starts at byte 6. Docs uniformly say byte 6 (MotionSensorManager.swift:12, CLAUDE.md:17, spec 2026-06-30 line 72). Either comment or parse wrong → garbage axes, desk-slap detection can't work. withMemoryRebound capacity 6 (24 bytes) for 22-byte report (:195-203) safe only due 4096 backing. Fix: unaligned-safe memcpy of 3 Int32 from report+6.
- [MEDIUM] Callback buffer lifetime: local &buffer passed :92,:104-110; kept only by reportBuffer property :93 niled on main :71 while reports arrive; sensorLoop exits on cancel :125-127 WITHOUT unscheduling → writes into freed array storage.
- [MEDIUM] Value-bar geometry wrong: ContentView.swift:125-131 barWidth=|v|/maxG*150, barOffset=v/maxG*150 at .offset(x:barOffset) :115 → centered ZStack bar spans [0.5v,1.5v]·(150/maxG): never starts at center marker (:107-109), overshoots by 50%.
- [MEDIUM] HOW_TO_USE.txt:20,:27 paths `/Users/jackson/Desktop/test` wrong (actual somno mac client/totem pop/test).
- [MEDIUM] Units contradiction: comment :205 "BMI286 driver outputs values already scaled to g-force", UI prints `g` (ContentView.swift:61,:96) vs HOW_TO_USE.txt:66 "Raw sensor output … Z ≈ -1.0 g" (CLAUDE.md:48 same) — unverifiable until #parse fixed against hardware.
- [LOW] :126 CFRunLoopRunInMode(defaultMode!, ...) force-unwrap on sensor thread; :125 isCancelled races main writes.
- [LOW] Every HID report dispatched to main unthrottled :211-216; "~20 Hz" claims (CLAUDE.md:47, HOW_TO_USE:9) unverified vs ReportInterval=1000 (:145-147, units unspecified).
- [LOW] CFNumberCreate results never CFRelease'd :141,:146 → leak per SPU service per wake.
- [HIGH plan-vs-status] Animation feature NOT implemented: spec 2026-06-30 line 4 Status: Approved plans TotemPop SPM package (animation overlay + hotkey/slap triggers); glob finds ZERO TotemPop*.swift; spec references nonexistent five-space path /Users/jackson/Desktop/     /claude/mac ui/totem pop/ (lines 128,165).
- OK: sudo handling coherent (build.sh:5-6,:30-31 only echo; build never escalates); build.sh compiles 3 files, checks $? (:27), exits 1 (:34); test/build/ empty (binary not committed, expected).
- TransparentVideoPlayer-master: vendored, 2-line README, NO LICENSE — unattributed (matches hygiene HIGH).

## black hole audit (subagent, grade B-)

Schwarzschild shader + Swift tuner app. No tests (single executable target).
- [HIGH] README refs missing scripts: black hole/ghostty-blackhole-main/README.md:97-98 `./demo-mode.sh on|off` (also blackhole.glsl:156) and :265-267 `./token-test.sh 0.42|sweep|off`; glob black hole/**/*.sh finds only tuner/make-app.sh.
- [MEDIUM] Work-area shield doesn't gate disk light: blackhole.glsl:422-424 comment "shield: warp/disk/stars all fade to nothing over the work area" — true for stars (:457,:472,:570) and displacement (:580) but disk emission emitc accumulated WITHOUT shield :555, composited unconditionally :589 `vec3 col = bg * trans + (vec3(1.0) - exp(-emitc * L.expo));` (trans darkening also unshielded) → near-field trace circle (b<bmax :442) over WORK_AREA band brightens/dims protected pixels; contradicts README.md:51 "never distorted" (position fine, brightness not). Fix: multiply emitc + trans term by shield.
- [MEDIUM] N_STEPS 48 (blackhole.glsl:71) paid by every pixel b<bmax=rout+3 (:442,:453); trace circle grows with hole (~3.1% shadow at token max), shader admits "~15M pixels x N_STEPS" (:68-70). NO early-out when window (:440) or shield (:424) ≈0; far-field branch (:453-474) always 3 texture fetches + stars() even when gated contribution ~0. README:258-262 tells users to lower N_STEPS.
- [MEDIUM] Tuner "Defaults" rewrites NON-shipped values. Shipped blackhole.glsl constants: HOLE_RADIUS 0.0200 :36, LENS_DEPTH 13.0 :37, DISK_INNER 1.8 :40, DISK_OUTER 8 :41, DISK_INCL 1.5 :42, DISK_ROLL 0.35 :43, DISK_GAIN 2.2 :45, DISK_OPACITY 0.9 :46, DISK_TEMP 5500 :47, DOPPLER_MIX 0.6 :48, DISK_BEAM 2.5 :49, DISK_SPEED 5.0 :50, DISK_WIND 7 :51, DISK_CONTRAST 1.6 :52, EXPOSURE 1.4 :54, TOKEN_HOME_X 0.96 :61, TOKEN_HOME_Y 0.04 :62. ParamSpec.swift defs differ for ALL: :27 0.08, :28 4.0, :32 3.0, :33 9, :34 1.45, :35 0.15, :36 1.0, :37 0.65, :38 3.6, :39 5.0, :40 0.9, :43 8500, :44 1.0, :45 3.0, :46 1.0, :57 0.94, :58 0.06. Defaults preset (ParamSpec.swift:79) + row resets (ContentView.swift:109, help :114) rewrite file to different look (4× hole, LENS_DEPTH 13→4). Shipped == "Inferno" preset (ParamSpec.swift:116-121; blackhole.glsl:155 calls Inferno "the defaults"); Specs.all.def stale second opinion. Fix: snapshot parsed file values as defaults.
- [MEDIUM] TOKEN_LEVEL slider dead as shipped: defineRe value group `(-?\d+\.\d+)` requires decimal (ShaderStore.swift:34-36) but `#define TOKEN_LEVEL -1 // token-level` blackhole.glsl:95 has none → parseFile (:89-105) never returns → Specs.grouped renders no row (ContentView.swift:10-21) → ParamSpec.swift:54 unreachable; README:207 false as shipped (hand-edit override README:150-151 works).
- [LOW/MED] /bin/ps synchronous on MAIN: flush()→reloadGhostty()→ghosttyTTYs()/ghosttyPIDs()→runPS (ShaderStore.swift:167,:235-253,:256-266; emitTokenLevel 2 more ps :214-228); slider drag ≈10 spawns/sec (flush debounce 0.09s :125) → jank. Fix: background queue.
- [LOW] Lifecycle: dir DispatchSource closes fd in cancel handler (ShaderStore.swift:283) but never cancelled in deinit; flushTimer/tokenTimer/rescanTimer (:24-26) not invalidated (latent — app-lifetime @StateObject).
- [LOW] locateShader() uses compile-time #filePath (:49-63) + cwd fallbacks + BLACKHOLE_SHADER env; tuner/make-app.sh copies only binary + Info.plist — shader not bundled, unsigned, no codesign → Gatekeeper prompt. README:215 `cd tuner && swift run` valid.
- [LOW] Trace budget: rays exhausting 48 steps use un-converged exit direction for sky projection (loop :497, projection :568-585); only r²<4 forced captured (:564) → mild displacement artifacts at low N_STEPS/large DISK_OUTER; horizon check :499 precedes drift so recomputed acceleration :514 can run r<1 (no div-by-zero, unphysical final step). No other NaN paths.
- VERIFIED-GOOD physics: x'' = -1.5·h²·x/r⁵ (blackhole.glsl:478-482) exact Schwarzschild null-geodesic Binet form for v=(0,0,-1); leapfrog :509-515; B_CRIT 3√3/2 :13; ISCO 3r_s (README:225), rin ≥1.6 outside photon sphere; division guards plen max 1e-4/1e-5 :455/:458, rh max 1e-4 :433, Doppler denom 0.05 :545, gloc 0.02 :534, d.z<-0.05 :571, b≥bmax>0 :471. tokenFromBytes checksum :99-104 deterministic → 1/65536 FP odds matching README:130; sRGB fallback :110-117 + glide iPreviousCursorColor/iTimeCursorChange :139-146 match README:135-140; tuner encoder matches shader (ShaderStore.swift:192-195).
- README install VERIFIED WORKS: `custom-shader`/`custom-shader-animation` real Ghostty options; both config paths (~/.config/ghostty/config, ~/Library/Application Support/com.mitchellh.ghostty/config) correct macOS locations; cmd+shift+, reload correct. NOT verified: Ghostty 1.3+ requirement (README:189), iDate caveat (README:77-82). README:107-111 area claims (0.06%/~3%) NOT drift — reconcile via * (HOLE_RADIUS/0.08) at blackhole.glsl:373. MIT LICENSE + Bruneton/BSD-3 attribution present (README:307-310).

## Cross-module (last 3 modules)
- No test targets in any Package.swift; totem pop's `test/` is app source, not tests.
- README/doc examples fail as written: GhostTrail `.cornerRadius(8)`; totem pop `/Users/jackson/Desktop/test`; black hole missing scripts.
- Read-only; nothing modified.

## Module identity (user instruction, m00127 — PERMANENT CONTEXT)
- polymorph = the user's OWN personal cursor changing module → renamed to **cursor changer** (folder + docs + SwiftPM names: CursorChanger / CursorChangerAgent / CursorChangerCLI). Always call it cursor changer.
- black hole = reference material the user placed in the repo; NOT a module to re-create or fix. Excluded from all fix rounds.
- Durable documentation written to `<project>/AGENTS.md` (module identities + audit history + conventions).

## Fix round 1 (running, 2026-10-02) — parallel agents
- 5ddbbb72 cursor trail fixes (H1-H4, M1-M8, L1-L12, real tests wired to swift test)
- 7b795236 desktop-canvas fixes (C1 build+tests, H1-H6, M1-M11, L1-L8)
- 392afbca ghost trail fixes (critical as!, behind-windows default, multi-display, tests)
- a7329048 totem pop fixes (HID lifecycle/parse, HOW_TO_USE, self-test harness; TotemPop animation explicitly NOT implemented)
- 938d9648 polymorph rename→cursor changer + H1-H3, M1-M5, lows, CLI, docs, honest TestRunner
- 764601d2 root hygiene (.gitignore, .trae, .vscode, root README, _inspect.py); NOT allowed git/mv of module media
- Orchestrator post-pass: git staging/rm --cached, git gc, final build+test verification of ALL packages.

## Fix round 2 (2026-10-02) — smaller briefs (round 1's oversized briefs killed 4 agents mid-run)
Lesson: the round-1 prompts were too big; agents produced no on-disk edits in ~45 min and 4 of 6 died. Relaunched with short step-ordered briefs demanding incremental saves.

### DONE — ghost trail (orchestrator did it directly)
Files: `ghost trail/Sources/GhostTrail/{GhostTrail,GhostTrailConfiguration,GhostTrailRenderer,GhostTrailWindow,WindowTracker}.swift`, NEW `TrailCoordinateConverter.swift`, NEW `Tests/GhostTrailTests/GhostTrailTests.swift`, `Package.swift`, `README.md`, `PROMPT.md`.
- CRITICAL `displayLink as! CVDisplayLink` (old GhostTrail.swift:181) trapped on macOS 13/14 → typed `legacyDisplayLink: CVDisplayLink?` property + `guard let`, no force-cast; `CVDisplayLinkCreateWithActiveCGDisplays`/`CVDisplayLinkStart` CVReturn checked; `start()` returns false + tears down window/tracker on failure.
- `Unmanaged.passRetained` self-retain leak → `passUnretained` + `displayLinkLock` serializing teardown.
- NEW `TrailCoordinateConverter`: quartz→cocoa y-flip about the MAIN display height, then subtract overlay origin. Overlay window now spans the UNION of all `NSScreen.screens` (`GhostTrailWindow.coveringFrame()`); renderer converts every rect before drawing, so trails land correctly on secondary displays (old code culled against `.zero`-origin rects).
- `fatalError("GhostTrail requires at least one display")` → 1×1 window + warning print.
- Default `windowLevel` `.aboveWindows` → `.behindWindows` (PROMPT.md:7 promised behind-the-window).
- `movementThreshold`/`jumpThreshold` were dead → both honored in WindowTracker poll + appendFrame.
- `.solid` style ignored `configuration.opacity` (layer alphas used raw constants) → scaled by baseOpacity. `.filled` squared alpha (`color.opacity(opacity)` then `* opacity * 0.3`) → fill now uses `color.opacity(opacity*0.3)`, stroke `color.opacity(opacity)`.
- 30Hz poll throttle (CGWindowListCopyWindowInfo was called every display-link frame at 60-120Hz).
- deinit no longer clobbers `GhostTrail.current` for other instances.
- Builder methods added: `.cornerRadius(_:)` (README documented it, it didn't exist), `.jumpThreshold(_:)`, `.windowLevel(_:)`.
- Tests: `swift test` went from 0 tests → 12 tests, 0 failures (RingBuffer 4, config clamping 2, converter 6 incl. secondary display left-of and above main).
- README: windowLevel default, frames "shrink"→fade, multi-display bullet, jumpThreshold row, architecture tree, Tests section. PROMPT.md: retain-pattern snippet marked superseded with rationale.

### IN FLIGHT (agents running)
- d7640bc7 cursor trail core; b053e83e desktop-canvas core; 3dbdca85 totem pop; cea0841c cursor changer remaining.
### Round 1 leftovers — CLOSED (2026-10-02)
Two commits landed:
- `a86f865` "Repo hygiene pass + polymorph -> cursor changer rename" — contains ONLY `.gitignore`,
  `.trae/rules/project_rules.md`, `.vscode/launch.json`, `AGENTS.md`, `README.md`, plus the two
  `git rm`'d totem pop media files. **Its message overstates the rename** — the rename was not
  in it. `.vscode/launch.json` + root README `polymorph`→`cursor changer` substitutions ARE in it.
- `75c1fb8` "Rename polymorph module to cursor changer" — the actual folder/package rename,
  36 files, staged with `git add -A polymorph "cursor changer"`. Verified 0 `polymorph/` paths left in HEAD.
- `_inspect.py` deleted; `cursor trail/.backup-orig/` (agent backup junk) deleted.

Lesson: `git add -A <oldpath> <newpath>` is required for git to record a moved folder as renames.
Adding only the new path leaves the old paths as untracked deletions and the rename is silently lost.

### Still uncommitted / untracked (must be `git add`ed with their module fixes)
- `ghost trail/Sources/GhostTrail/TrailCoordinateConverter.swift`, `ghost trail/Tests/`
- `desktop-canvas/Sources/DesktopCanvas/{BrushTool,ScreenGeometry}.swift`, `desktop-canvas/Tests/`
- `totem pop/test/{AxisBarGeometry,SelfTest}.swift`
- `cursor trail/.vscode/` — agent-created; root `.gitignore` covers `.vscode/*` but the dir must be removed.
- Optional: `git gc --aggressive` (446 loose objects before these commits).

## Fix round 2 — COMPLETE (2026-10-02)

All P0–P2 findings across cursor trail, desktop-canvas, ghost trail, totem pop and
cursor changer are fixed and committed. `black hole/` untouched (reference-only).
10 commits, `51df8c4` (AGENTS.md) .. `a86f865`. Working tree clean.

### Final verification — `/Users/jackson/Documents/deepseek-harness/default-workspace/verify-all.sh`
13/13 checks PASS (full sweep output in /tmp/somno-verify-out.txt):
- cursor trail: build OK, 46 swift-testing tests
- desktop-canvas: build OK, 112 XCTest (was: build FAILED, 0 tests)
- ghost trail: build OK, 12 XCTest (was: crash on first start() on macOS 13/14, 0 tests)
- cursor changer: build OK, 209 TestRunner assertions (was: 78)
- totem pop: build.sh + self-test PASS (7 groups / ~70 assertions)
- black hole tuner: build OK

### Harness lessons (verify-all.sh v3)
Three separate bugs in my own verification script produced FAKE failures, and one
produced a fake PASS. Recorded so the next person does not repeat them:
1. `RESULT` prefix collided with cursor changer's own `RESULT: PASS` output line →
   the script counted its own bookkeeping. Renamed all bookkeeping to `CHECK`.
2. Test-count guard was applied to `swift build` runs, which execute no tests by
   definition → 4 spurious "dead code" FAILs. Guard now applies only to test runs.
3. Counted only swift-testing + XCTest, missing the third harness's
   `Total: N assertions` line → cursor changer's 209 assertions scored as 0.
4. `swift test` exits 1 with "no tests found" for a package whose tests are an
   executable target (cursor changer). Script now drops that FAIL and scores the
   TestRunner instead. This is the one case where a nonzero exit is correct.
5. `$OUT="${1:-...}"` — `OUT="$1"` + `: "${OUT:=...}"` under `set -u` aborts the
   whole script on a missing argument.
Rule that held throughout: never trust an exit code alone in this repo. Every suite
here shipped at some point as code that compiled, exited 0, and ran nothing.

### desktop-canvas — agent b053e83e deviation, reviewed and accepted
The brief told the agent to y-flip canvas frames in the window path. It declined,
with evidence: `CanvasWindow.init` places the window at `screen.frame`, so
`NSWindow.frame`, `NSScreen.frame` and stored `CanvasLayout` frames are all the same
bottom-left y-up Cocoa space — flipping there mirrors every canvas (a dock-side
canvas would land at the menu bar). Two new tests caught the agent's own first
attempt at flipping both paths (`testPreviewRectRoundTripsThroughCanvasPoint` y 580
vs 780; `testPreviewMappingAgreesWithTheWindowMapping` y 130 vs 255). Final split:
`ScreenGeometry.localFrame` translates only; `previewRect` flips, because the
editor preview draws document-style top-down. Pinned by
`testScreenMapperDoesNotMirrorVertically`. Orchestrator read
`ScreenGeometry.swift:10-45` and `CanvasWindow.swift:98-146` and agrees.

### Other agent findings beyond the brief (all fixed, in 06bbaed)
- `GridEditorView.flushAndResume` had an **inverted condition** — it resumed when
  `!wasPlaying`, so closing the grid editor paused a running sim and started a
  paused one. This was NOT in the audit.
- `snapCornerResize` assigned size without re-anchoring origin → `.topLeft` handle jumped.
- `RuleSet.init?(bSNotation:)` rejected `B33/S23`, i.e. duplicates caused a preset-table
  entry to be rejected.
- Metal `fatalError` on missing device replaced with a recorded `initializationError`.
- `OverlapResolver.resolve(moving:excluding:against:preferredDirection:)` implemented and
  wired into live drag (was a spec feature with no implementation) — 0.35s red flash border.

### Repo-wide hygiene done in this round
- 43 absolute paths removed from 9 `docs/superpowers/{plans,specs}/*.md` files, incl. a
  five-literal-space path that never existed (`/Users/jackson/Desktop/     /claude/mac ui`).
- The 2 desktop-canvas Spike harnesses no longer hardcode a specific video from the original
  author's Desktop; both take the path as argv[1] and print usage when missing.
- `grep -rn "/Users/jackson" --include=*.{md,swift,txt,json,sh}` → **0 matches** outside `.build/`.

### Left undone (deliberate, documented)
- `git gc --aggressive` (446 loose objects) — cosmetic, no functional impact.
- Two root commits (ddb9b0c, fdbe89a) and duplicate commit messages — history rewriting
  via `git filter-repo` is riskier than the benefit justifies; recommended before any
  public push.
- TotemPop `accelScale = 65536` divisor — agent flagged it as needing hardware verification
  (leave the Mac flat, magnitude should read ≈1.0 g). Cannot be verified headlessly.
- TotemPop's TotemPop animation remains unimplemented; its design spec says "Approved",
  which is aspirational, not a commitment (AGENTS.md:22-23 records this).
- `black hole/` shield does not gate disk emission; tuner "Defaults" button rewrites all 17
  constants to non-shipped values — both reference-only, deliberately untouched.
