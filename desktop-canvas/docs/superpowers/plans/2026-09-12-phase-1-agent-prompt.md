# Phase 1: Package Scaffold & Models — Agent Prompt

## Your task

Implement Phase 1 of DesktopCanvas: create the SwiftPM package scaffold and all data model types. This is pure data — no rendering, no Metal, no AppKit windows. Just Codable structs.

After you're done, verify with `swift build`. The package must compile with zero errors and zero warnings.

---

## Project context

You're working on the **Somno Mac Client** monorepo at:

```
./
```

This repo contains multiple macOS modules. The one we care about is `desktop-canvas/`.

**DesktopCanvas** renders dynamic content (MP4 videos + Game of Life procedural art) behind macOS desktop icons, using a desktop-level `NSWindow`. Think "video wallpaper" + "Conway's Game of Life art" on the desktop.

The design is confirmed by 5 research spikes in `desktop-canvas/Spike/` (see REPORT.md). The approach works. Now we're building it for real.

---

## Existing module to follow: CursorTrail

The repo already has a sibling module at `cursor trail/Package.swift`. DesktopCanvas should follow the same conventions. Here's the full CursorTrail Package.swift for reference:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CursorTrail",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CursorTrail",
            targets: ["CursorTrail"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CursorTrail",
            dependencies: [],
            path: "Sources/CursorTrail",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "CursorTrailTests",
            dependencies: ["CursorTrail"],
            path: "Tests/CursorTrailTests"
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["CursorTrail"],
            path: "Tests/TestRunner"
        ),
        .executableTarget(
            name: "CursorTrailDemo",
            dependencies: ["CursorTrail"],
            path: "Examples/CursorTrailDemo"
        )
    ]
)
```

Key convention: same `swift-tools-version`, same `platforms`, same structure. DesktopCanvas diverges in one way — see next section.

---

## Decisions already made (do NOT change these)

1. **`CodableColor` is raw RGBA, not `NSColor` or SwiftUI `Color`.**
   Reason: The library stays framework-agnostic so it doesn't need to import AppKit or SwiftUI just for a color type. The demo app will bridge to SwiftUI `Color` later with `Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)`.

2. **No umbrella header.**
   Unlike CursorTrail (which uses `publicHeadersPath: "."`), DesktopCanvas has zero Objective-C interop. No `.h` file. No `publicHeadersPath`.

3. **No `BrushTool.swift` in this phase.**
   The master plan lists BrushTool as task 1.6, but it's only used by the grid editor in Phase 10. Deferred.

4. **Video URLs are local file URLs only.**
   `VideoConfig.videoURL` is a file path, not a remote URL. No network streaming support in v0.1.

5. **No test target or demo executable yet.**
   Tests come in Phase 12. Demo app comes in Phase 8. Phase 1 is library-only.

---

## Phase 0 research findings (the agent should know these)

From testing on macOS Tahoe 26.6.2 (all 5 spikes passed):

- **Window level**: `CGWindowLevelForKey(.desktopIconWindow)` raw value `-2147483603` is the winning level — renders behind icons, icons remain clickable, survives Mission Control and Space switches.
- **Compositing**: MTKView + AVPlayerLayer coexist without flicker or artifacts. Desktop video wallpaper works.
- **Permissions**: Zero dialogs triggered. No Screen Recording or Accessibility permissions needed.
- **Game of Life**: Metal compute kernel at 500×500 cells runs smoothly at 60fps. Double-buffer ping-pong works.
- **Video looping**: ~55ms seek gap per loop, barely noticeable. No crossfade needed.

Full report: `desktop-canvas/Spike/REPORT.md`

---

## Design spec (the Canvas model)

Here's the exact model the library needs. It comes from `desktop-canvas/docs/superpowers/specs/2026-09-12-desktop-canvas-design.md`:

```swift
struct CanvasLayout: Codable {
    var name: String
    var canvases: [Canvas]
}

struct Canvas: Codable, Identifiable {
    var id: UUID
    var type: CanvasType
    var frame: CGRect
    var gameOfLifeConfig: GameOfLifeConfig?
    var videoConfig: VideoConfig?
}

enum CanvasType: String, Codable {
    case gameOfLife
    case video
}

struct GameOfLifeConfig: Codable {
    var ruleSet: RuleSet
    var cellSize: Int
    var aliveColor: CodableColor
    var deadColor: CodableColor
    var marginColor: CodableColor
    var generationsPerSecond: Double
    var gridState: [[Bool]]?
    var paused: Bool
}

struct VideoConfig: Codable {
    var videoURL: URL
    var volume: Double
    var loop: Bool
}

struct RuleSet: Codable, Equatable {
    var name: String
    var birth: Set<Int>
    var survival: Set<Int>
}
```

**Canvas rules from the spec:**
- Minimum canvas size: 32×32 points. Enforce this in `Canvas.init`.
- Minimum cell size: 2 points. Grid dimensions: `cols = floor(canvasWidth / cellSize)`, `rows = floor(canvasHeight / cellSize)`. (Not enforced in this phase — just the model.)
- Canvases may not overlap (enforced later by `OverlapResolver` in Phase 6).

---

## 9 preset rule sets

The spec defines these presets. They must be available as `RuleSet.presets`:

| Name | Notation | Birth | Survival |
|---|---|---|---|
| Conway | B3/S23 | 3 | 2, 3 |
| HighLife | B36/S23 | 3, 6 | 2, 3 |
| Day & Night | B3678/S34678 | 3, 6, 7, 8 | 3, 4, 6, 7, 8 |
| Seeds | B2/S | 2 | (empty) |
| Maze | B3/S12345 | 3 | 1, 2, 3, 4, 5 |
| Anneal | B4678/S35678 | 4, 6, 7, 8 | 3, 5, 6, 7, 8 |
| 2x2 | B36/S125 | 3, 6 | 1, 2, 5 |
| Morley | B368/S245 | 3, 6, 8 | 2, 4, 5 |
| Diamoeba | B35678/S5678 | 3, 5, 6, 7, 8 | 5, 6, 7, 8 |

Plus a `RuleSet(bSNotation:)` failable initializer that parses `"B3/S23"` strings, and a `bSNotation` computed property that formats back to that string. The parser must reject invalid input (wrong format, non-digit characters, etc.) by returning `nil`.

---

## Files to create (exact content)

### File 1: `desktop-canvas/Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopCanvas",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "DesktopCanvas",
            targets: ["DesktopCanvas"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DesktopCanvas",
            dependencies: [],
            path: "Sources/DesktopCanvas",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
```

Differences from CursorTrail's Package.swift:
- No `publicHeadersPath` (no ObjC)
- Linker frameworks: AppKit, Metal, AVFoundation, QuartzCore (DesktopCanvas needs Metal/AVFoundation; CursorTrail doesn't)
- No `.testTarget` or `.executableTarget` entries yet

### File 2: `desktop-canvas/Sources/DesktopCanvas/CodableColor.swift`

Why a separate file: CodableColor is used by multiple types (GameOfLifeConfig, potentially future configs). Small enough to be its own file so imports stay clean.

```swift
import Foundation

struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let black = CodableColor(red: 0, green: 0, blue: 0)
    static let white = CodableColor(red: 1, green: 1, blue: 1)
    static let clear = CodableColor(red: 0, green: 0, blue: 0, alpha: 0)
}
```

### File 3: `desktop-canvas/Sources/DesktopCanvas/CanvasLayout.swift`

```swift
import Foundation

struct CanvasLayout: Codable {
    var name: String
    var canvases: [Canvas]

    static func load(from url: URL) throws -> CanvasLayout {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CanvasLayout.self, from: data)
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url)
    }
}
```

### File 4: `desktop-canvas/Sources/DesktopCanvas/Canvas.swift`

```swift
import Foundation

enum CanvasType: String, Codable, CaseIterable {
    case gameOfLife
    case video
}

struct GameOfLifeConfig: Codable {
    var ruleSet: RuleSet
    var cellSize: Int
    var aliveColor: CodableColor
    var deadColor: CodableColor
    var marginColor: CodableColor
    var generationsPerSecond: Double
    var gridState: [[Bool]]?
    var paused: Bool

    static let `default` = GameOfLifeConfig(
        ruleSet: .conway,
        cellSize: 4,
        aliveColor: CodableColor(red: 0.2, green: 0.9, blue: 0.3),
        deadColor: CodableColor(red: 0.05, green: 0.05, blue: 0.05),
        marginColor: CodableColor(red: 0.02, green: 0.02, blue: 0.02),
        generationsPerSecond: 30,
        gridState: nil,
        paused: false
    )
}

struct VideoConfig: Codable {
    var videoURL: URL
    var volume: Double
    var loop: Bool

    static let `default` = VideoConfig(
        videoURL: URL(fileURLWithPath: ""),
        volume: 0.0,
        loop: true
    )
}

struct Canvas: Codable, Identifiable {
    var id: UUID
    var type: CanvasType
    var frame: CGRect
    var gameOfLifeConfig: GameOfLifeConfig?
    var videoConfig: VideoConfig?

    init(
        id: UUID = UUID(),
        type: CanvasType,
        frame: CGRect,
        gameOfLifeConfig: GameOfLifeConfig? = nil,
        videoConfig: VideoConfig? = nil
    ) {
        self.id = id
        self.type = type
        self.frame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: max(frame.width, 32),
            height: max(frame.height, 32)
        )
        self.gameOfLifeConfig = gameOfLifeConfig
        self.videoConfig = videoConfig
    }
}
```

Note: `CGRect` is Codable by default in Swift. `RuleSet` is in a separate file.

### File 5: `desktop-canvas/Sources/DesktopCanvas/RuleSet.swift`

```swift
import Foundation

struct RuleSet: Codable, Equatable {
    var name: String
    var birth: Set<Int>
    var survival: Set<Int>

    init(name: String, birth: Set<Int>, survival: Set<Int>) {
        self.name = name
        self.birth = birth
        self.survival = survival
    }

    init?(bSNotation: String) {
        let parts = bSNotation.split(separator: "/")
        guard parts.count == 2 else { return nil }

        let birthPart = parts[0]
        let survivalPart = parts[1]

        guard birthPart.hasPrefix("B"), survivalPart.hasPrefix("S") else { return nil }

        let birthDigits = birthPart.dropFirst()
        let survivalDigits = survivalPart.dropFirst()

        let birthSet = Set(birthDigits.compactMap { Int(String($0)) })
        let survivalSet = Set(survivalDigits.compactMap { Int(String($0)) })

        guard birthSet.count == birthDigits.count,
              survivalSet.count == survivalDigits.count else { return nil }

        self.name = "Custom"
        self.birth = birthSet
        self.survival = survivalSet
    }

    var bSNotation: String {
        let b = birth.sorted().map(String.init).joined()
        let s = survival.sorted().map(String.init).joined()
        return "B\(b)/S\(s)"
    }

    static let conway   = RuleSet(name: "Conway",      birth: [3],             survival: [2, 3])
    static let highLife = RuleSet(name: "HighLife",    birth: [3, 6],          survival: [2, 3])
    static let dayNight = RuleSet(name: "Day & Night", birth: [3, 6, 7, 8],    survival: [3, 4, 6, 7, 8])
    static let seeds    = RuleSet(name: "Seeds",       birth: [2],             survival: [])
    static let maze     = RuleSet(name: "Maze",        birth: [3],             survival: [1, 2, 3, 4, 5])
    static let anneal   = RuleSet(name: "Anneal",      birth: [4, 6, 7, 8],    survival: [3, 5, 6, 7, 8])
    static let twoByTwo = RuleSet(name: "2x2",         birth: [3, 6],          survival: [1, 2, 5])
    static let morley   = RuleSet(name: "Morley",      birth: [3, 6, 8],       survival: [2, 4, 5])
    static let diamoeba = RuleSet(name: "Diamoeba",    birth: [3, 5, 6, 7, 8], survival: [5, 6, 7, 8])

    static let presets: [RuleSet] = [
        .conway, .highLife, .dayNight, .seeds, .maze,
        .anneal, .twoByTwo, .morley, .diamoeba
    ]
}
```

---

## Verification

After creating all files, run:

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
│       ├── CodableColor.swift
│       ├── CanvasLayout.swift
│       ├── Canvas.swift
│       └── RuleSet.swift
├── Spike/                          (already exists, do NOT touch)
├── docs/                           (already exists, do NOT touch)
```

---

## Out of scope (do NOT create these)

- `BrushTool.swift` (Phase 10, grid editor)
- `CanvasProvider.swift` (Phase 2, protocol)
- `CanvasRenderer.swift` (Phase 2)
- `GameOfLifeProvider.swift` (Phase 3, Metal)
- `VideoProvider.swift` (Phase 4, AVPlayer)
- `CanvasWindow.swift` (Phase 5)
- `ScreenManager.swift` (Phase 5)
- `DesktopCanvas.swift` (Phase 5, main entry point)
- `OverlapResolver.swift` (Phase 6)
- Demo app in `Examples/` (Phase 8)
- Tests in `Tests/` (Phase 12)
- Any `.metal` shader files (Phase 3)
- Any `.h` umbrella header (not needed)
- `.md` documentation files (Phase 13)