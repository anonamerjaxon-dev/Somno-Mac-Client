# Cursor Trail Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a system-wide macOS cursor trail library that replaces the system cursor and renders a customizable trail overlay at 60fps.

**Architecture:** A Swift Package with a builder-pattern API. The library creates a transparent overlay window at screen-saver level, hides the system cursor via `CGDisplayHideCursor`, and draws the trail using SwiftUI Canvas. Cursor positions are sampled on a display link timer for smooth 60fps rendering. Trail points are stored in a ring buffer and rendered as either a line or ribbon with optional glow, particles, and blur effects.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, CoreGraphics, QuartzCore (CADisplayLink), Swift Package Manager

---

## File Structure

```
cursor trail/
├── Package.swift
├── README.md
├── Sources/
│   └── CursorTrail/
│       ├── CursorTrail.swift              # Main entry point (builder class)
│       ├── TrailConfiguration.swift       # Configuration struct
│       ├── TrailStyle.swift               # Style enum (line, ribbon)
│       ├── TrailColor.swift               # Color types (solid, gradient, rainbow)
│       ├── SpeedMode.swift                # Speed mode enum
│       ├── GlowConfig.swift               # Glow configuration
│       ├── ParticleConfig.swift           # Particle configuration
│       ├── BlurConfig.swift               # Blur configuration
│       ├── TrailPoint.swift               # Trail point data model
│       ├── RingBuffer.swift               # Fixed-size ring buffer for points
│       ├── TrailWindow.swift              # Transparent overlay NSWindow
│       ├── TrailRenderer.swift            # SwiftUI Canvas-based renderer
│       ├── CursorManager.swift            # System cursor hide/show
│       ├── PermissionsManager.swift       # Accessibility & screen recording checks
│       └── CursorTrail.h                  # Umbrella header
└── Tests/
    └── CursorTrailTests/
        ├── CursorTrailTests.swift
        ├── RingBufferTests.swift
        ├── TrailConfigurationTests.swift
        └── TrailRendererTests.swift
```

---

### Task 1: Project Scaffolding & Package.swift

**Files:**
- Create: `cursor trail/Package.swift`
- Create: `cursor trail/Sources/CursorTrail/CursorTrail.h`
- Create: `cursor trail/Tests/CursorTrailTests/CursorTrailTests.swift` (placeholder)

- [ ] **Step 1: Create Package.swift**

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
        )
    ]
)
```

- [ ] **Step 2: Create umbrella header**

```objc
// CursorTrail.h
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

FOUNDATION_EXPORT double CursorTrailVersionNumber;
FOUNDATION_EXPORT const unsigned char CursorTrailVersionString[];
```

- [ ] **Step 3: Create placeholder test file**

```swift
import XCTest
@testable import CursorTrail

final class CursorTrailTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: Verify package builds**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds with no errors

- [ ] **Step 5: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "chore: scaffold Swift Package for CursorTrail"
```

---

### Task 2: TrailPoint & RingBuffer (Data Layer)

**Files:**
- Create: `cursor trail/Sources/CursorTrail/TrailPoint.swift`
- Create: `cursor trail/Sources/CursorTrail/RingBuffer.swift`
- Create: `cursor trail/Tests/CursorTrailTests/RingBufferTests.swift`

- [ ] **Step 1: Write failing RingBuffer test**

```swift
import XCTest
@testable import CursorTrail

final class RingBufferTests: XCTestCase {
    func testEmptyBuffer() {
        let buffer = RingBuffer<Int>(capacity: 5)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertFalse(buffer.isFull)
        XCTAssertEqual(buffer.count, 0)
    }

    func testAppendUntilFull() {
        let buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.count, 3)
    }

    func testOverwriteOldest() {
        let buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        buffer.append(4) // overwrites 1
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer[0], 2) // oldest is now 2
        XCTAssertEqual(buffer[2], 4) // newest is 4
    }

    func testClear() {
        let buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "cursor trail" && swift test --filter RingBufferTests`
Expected: FAIL — "RingBuffer is not defined"

- [ ] **Step 3: Create TrailPoint.swift**

```swift
import Foundation
import CoreGraphics

/// Represents a single point in the cursor trail.
struct TrailPoint {
    let position: CGPoint
    let timestamp: CFTimeInterval
    let velocity: CGFloat // pixels per second

    init(position: CGPoint, timestamp: CFTimeInterval = CACurrentMediaTime(), velocity: CGFloat = 0) {
        self.position = position
        self.timestamp = timestamp
        self.velocity = velocity
    }
}
```

- [ ] **Step 4: Create RingBuffer.swift**

```swift
import Foundation

/// Fixed-size ring buffer for efficient trail point storage.
/// When full, new entries overwrite the oldest.
struct RingBuffer<T> {
    private var storage: [T?]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0
    private let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }
    var size: Int { count }

    mutating func append(_ element: T) {
        storage[tail] = element
        if isFull {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
        tail = (tail + 1) % capacity
    }

    mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        tail = 0
        count = 0
    }

    subscript(index: Int) -> T {
        precondition(index >= 0 && index < count, "Index out of bounds")
        let actualIndex = (head + index) % capacity
        return storage[actualIndex]!
    }

    func toArray() -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(self[i])
        }
        return result
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd "cursor trail" && swift test --filter RingBufferTests`
Expected: All 4 tests PASS

- [ ] **Step 6: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add TrailPoint and RingBuffer data structures"
```

---

### Task 3: Configuration Types

**Files:**
- Create: `cursor trail/Sources/CursorTrail/TrailStyle.swift`
- Create: `cursor trail/Sources/CursorTrail/TrailColor.swift`
- Create: `cursor trail/Sources/CursorTrail/SpeedMode.swift`
- Create: `cursor trail/Sources/CursorTrail/GlowConfig.swift`
- Create: `cursor trail/Sources/CursorTrail/ParticleConfig.swift`
- Create: `cursor trail/Sources/CursorTrail/BlurConfig.swift`
- Create: `cursor trail/Sources/CursorTrail/TrailConfiguration.swift`
- Create: `cursor trail/Tests/CursorTrailTests/TrailConfigurationTests.swift`

- [ ] **Step 1: Write failing configuration test**

```swift
import XCTest
@testable import CursorTrail

final class TrailConfigurationTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = TrailConfiguration()
        XCTAssertEqual(config.thickness, 3.0)
        XCTAssertEqual(config.length, 100)
        XCTAssertEqual(config.style, .line)
        XCTAssertEqual(config.speedMode, .adaptive)
        XCTAssertNil(config.glow)
        XCTAssertNil(config.particles)
        XCTAssertNil(config.blur)
    }

    func testCustomConfiguration() {
        let config = TrailConfiguration(
            color: .gradient(.red, .blue),
            thickness: 6,
            length: 200,
            style: .ribbon,
            speedMode: .fixed,
            glow: GlowConfig(radius: 10, intensity: 0.6),
            particles: ParticleConfig(shape: .star, count: 8, lifetime: 1.5),
            blur: BlurConfig(radius: 5)
        )
        XCTAssertEqual(config.thickness, 6)
        XCTAssertEqual(config.length, 200)
        XCTAssertEqual(config.style, .ribbon)
        XCTAssertNotNil(config.glow)
        XCTAssertNotNil(config.particles)
        XCTAssertNotNil(config.blur)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "cursor trail" && swift test --filter TrailConfigurationTests`
Expected: FAIL — types not defined

- [ ] **Step 3: Create TrailStyle.swift**

```swift
import Foundation

/// Visual style of the cursor trail.
public enum TrailStyle: Sendable {
    case line
    case ribbon
}
```

- [ ] **Step 4: Create TrailColor.swift**

```swift
import SwiftUI

/// Color configuration for the trail.
public enum TrailColor: Sendable {
    case solid(Color)
    case gradient(Color, Color)
    case rainbow

    var colors: [Color] {
        switch self {
        case .solid(let c):
            return [c]
        case .gradient(let c1, let c2):
            return [c1, c2]
        case .rainbow:
            return [.red, .orange, .yellow, .green, .blue, .purple]
        }
    }
}
```

- [ ] **Step 5: Create SpeedMode.swift**

```swift
import Foundation

/// How the trail reacts to cursor speed.
public enum SpeedMode: Sendable {
    case fixed
    case adaptive
}
```

- [ ] **Step 6: Create GlowConfig.swift**

```swift
import SwiftUI

/// Configuration for optional glow effect.
public struct GlowConfig: Sendable {
    let radius: CGFloat
    let intensity: Double // 0.0–1.0
    let color: Color?

    public init(radius: CGFloat = 8, intensity: Double = 0.5, color: Color? = nil) {
        self.radius = radius
        self.intensity = min(max(intensity, 0), 1)
        self.color = color
    }
}
```

- [ ] **Step 7: Create ParticleConfig.swift**

```swift
import SwiftUI

/// Shape of particles for the particle effect.
public enum ParticleShape: Sendable {
    case circle
    case star
    case heart
    case square
}

/// Configuration for optional particle effect.
public struct ParticleConfig: Sendable {
    let shape: ParticleShape
    let count: Int
    let lifetime: Double // seconds
    let size: CGFloat
    let color: Color

    public init(
        shape: ParticleShape = .circle,
        count: Int = 5,
        lifetime: Double = 1.0,
        size: CGFloat = 4,
        color: Color = .white
    ) {
        self.shape = shape
        self.count = max(count, 1)
        self.lifetime = max(lifetime, 0.1)
        self.size = max(size, 1)
        self.color = color
    }
}
```

- [ ] **Step 8: Create BlurConfig.swift**

```swift
import Foundation

/// Configuration for optional blur effect.
public struct BlurConfig: Sendable {
    let radius: CGFloat

    public init(radius: CGFloat = 5) {
        self.radius = max(radius, 0)
    }
}
```

- [ ] **Step 9: Create TrailConfiguration.swift**

```swift
import SwiftUI

/// Complete configuration for a cursor trail.
public struct TrailConfiguration: Sendable {
    public var color: TrailColor
    public var thickness: CGFloat
    public var length: Int
    public var style: TrailStyle
    public var speedMode: SpeedMode
    public var glow: GlowConfig?
    public var particles: ParticleConfig?
    public var blur: BlurConfig?

    public init(
        color: TrailColor = .solid(.cyan),
        thickness: CGFloat = 3,
        length: Int = 100,
        style: TrailStyle = .line,
        speedMode: SpeedMode = .adaptive,
        glow: GlowConfig? = nil,
        particles: ParticleConfig? = nil,
        blur: BlurConfig? = nil
    ) {
        self.color = color
        self.thickness = max(thickness, 1)
        self.length = max(length, 10)
        self.style = style
        self.speedMode = speedMode
        self.glow = glow
        self.particles = particles
        self.blur = blur
    }
}
```

- [ ] **Step 10: Run test to verify it passes**

Run: `cd "cursor trail" && swift test --filter TrailConfigurationTests`
Expected: All tests PASS

- [ ] **Step 11: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add configuration types (TrailColor, Style, Speed, Glow, Particles, Blur)"
```

---

### Task 4: Permissions Manager

**Files:**
- Create: `cursor trail/Sources/CursorTrail/PermissionsManager.swift`

- [ ] **Step 1: Create PermissionsManager.swift**

```swift
import Foundation
import ApplicationServices

/// Manages system permissions required for cursor trail.
public enum PermissionsManager {

    /// Check if the process has accessibility permission (needed to hide cursor).
    public static var hasAccessibilityPermission: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Check if the process can record the screen (needed for overlay).
    public static var hasScreenRecordingPermission: Bool {
        guard let mainDisplay = CGMainDisplayID() else { return false }
        let displayBounds = CGDisplayBounds(mainDisplay)
        let capture = CGDisplayCreateImage(displayBounds)
        return capture != nil
    }

    /// Open System Preferences > Privacy & Security > Accessibility.
    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Open System Preferences > Privacy & Security > Screen Recording.
    public static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add PermissionsManager for accessibility and screen recording checks"
```

---

### Task 5: Cursor Manager (Cursor Replacement)

**Files:**
- Create: `cursor trail/Sources/CursorTrail/CursorManager.swift`

> **NOTE:** This is the core of how we replace the system cursor. Document this carefully in the README.

- [ ] **Step 1: Create CursorManager.swift**

```swift
import Foundation
import CoreGraphics

/// Manages hiding and showing the system cursor.
///
/// ## How Cursor Replacement Works
///
/// macOS provides `CGDisplayHideCursor(displayID)` which hides the cursor
/// for the entire display. Combined with `CGDisplayShowCursor(displayID)`,
/// we can toggle cursor visibility.
///
/// The key insight: when the cursor is hidden, we still receive mouse
/// event data (mouseMoved, mouseDragged). We use this to track position
/// and draw our own custom cursor + trail in the overlay window.
///
/// ## Permissions Required
///
/// - **Accessibility:** Required to call `CGDisplayHideCursor` on macOS 11+.
///   Without this, the system may re-show the cursor immediately.
/// - **Screen Recording:** Required for the overlay window to appear on screen.
///
/// ## Implementation Details
///
/// 1. `hideCursor()` calls `CGDisplayHideCursor(CGMainDisplayID())`
/// 2. We store the cursor's last known position via `NSEvent.mouseLocation`
/// 3. The overlay window draws a custom cursor at that position
/// 4. `showCursor()` calls `CGDisplayShowCursor(CGMainDisplayID())`
///
/// Important: `CGDisplayShowCursor` must be called the same number of times
/// as `CGDisplayHideCursor` (it's reference-counted). We track this with
/// a hide count to prevent double-show.

public final class CursorManager {
    private static var hideCount: Int = 0
    private static var isHidden: Bool = false

    /// Hide the system cursor. Safe to call multiple times (reference counted).
    public static func hideCursor() {
        guard !isHidden else {
            hideCount += 1
            return
        }

        let displayID = CGMainDisplayID()
        let error = CGDisplayHideCursor(displayID)
        guard error == .success else {
            print("CursorTrail: Failed to hide cursor (error: \(error)). Accessibility permission may be required.")
            return
        }

        isHidden = true
        hideCount = 1
    }

    /// Show the system cursor. Only shows when all hides have been balanced.
    public static func showCursor() {
        guard isHidden else { return }

        hideCount -= 1
        guard hideCount <= 0 else { return }

        let displayID = CGMainDisplayID()
        let error = CGDisplayShowCursor(displayID)
        guard error == .success else {
            print("CursorTrail: Failed to failed to show cursor (error: \(error)).")
            return
        }

        isHidden = false
        hideCount = 0
    }

    /// Whether the system cursor is currently hidden.
    public static var cursorHidden: Bool {
        return isHidden
    }

    /// Current mouse location in screen coordinates (bottom-left origin).
    public static var currentMouseLocation: CGPoint {
        NSEvent.mouseLocation
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add CursorManager for system cursor hide/show with reference counting"
```

---

### Task 6: TrailWindow (Transparent Overlay)

**Files:**
- Create: `cursor trail/Sources/CursorTrail/TrailWindow.swift`

- [ ] **Step 1: Create TrailWindow.swift**

```swift
import SwiftUI
import AppKit

/// Transparent overlay window that floats above all other content.
/// This is where the cursor trail is drawn.
final class TrailWindow: NSWindow {

    private let hostingController: NSHostingController<TrailContentView>

    init() {
        let contentView = TrailContentView()
        let hostingController = NSHostingController(rootView: contentView)

        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.hostingController = hostingController
        self.contentViewController = hostingController

        // Make it transparent and float above everything
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true // Clicks pass through
        self.level = .screenSaver // Above all normal windows
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Cover all screens
        self.setFrame(NSScreen.main?.frame ?? .zero, display: true)
    }

    func updateRenderer(_ renderer: TrailRenderer) {
        (contentView as? TrailContentView)?.updateRenderer(renderer)
    }

    func updateTrailPoints(_ points: [TrailPoint]) {
        (contentView as? TrailContentView)?.updateTrailPoints(points)
    }
}

/// SwiftUI view that hosts the Canvas for rendering the trail.
struct TrailContentView: View {
    @State private var renderer: TrailRenderer?
    @State private var trailPoints: [TrailPoint] = []

    var body: some View {
        ZStack {
            if let renderer = renderer {
                Canvas { context, size in
                    renderer.draw(context: context, size: size, points: trailPoints)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func updateRenderer(_ renderer: TrailRenderer) {
        self.renderer = renderer
    }

    func updateTrailPoints(_ points: [TrailPoint]) {
        self.trailPoints = points
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add TrailWindow transparent overlay with SwiftUI Canvas hosting"
```

---

### Task 7: TrailRenderer (Drawing Engine)

**Files:**
- Create: `cursor trail/Sources/CursorTrail/TrailRenderer.swift`

- [ ] **Step 1: Create TrailRenderer.swift**

```swift
import SwiftUI

/// Renders the cursor trail onto a SwiftUI GraphicsContext.
/// Uses path-based drawing for smooth lines and ribbons.
public final class TrailRenderer {
    private let configuration: TrailConfiguration

    public init(configuration: TrailConfiguration) {
        self.configuration = configuration
    }

    /// Draw the trail into the given SwiftUI graphics context.
    public func draw(context: GraphicsContext, size: CGSize, points: [TrailPoint]) {
        guard points.count >= 2 else { return }

        switch configuration.style {
        case .line:
            drawLine(context: context, points: points)
        case .ribbon:
            drawRibbon(context: context, points: points)
        }

        // Draw optional effects
        if let glow = configuration.glow {
            drawGlow(context: context, points: points, glow: glow)
        }

        if let particles = configuration.particles {
            drawParticles(context: context, points: points, particles: particles)
        }

        // Draw custom cursor at the latest point
        if let latest = points.last {
            drawCustomCursor(context: context, at: latest)
        }
    }

    // MARK: - Line Drawing

    private func drawLine(context: GraphicsContext, points: [TrailPoint]) {
        let path = createSmoothPath(points: points)

        let strokeColor = colorForTrail(index: 0, total: points.count)
        let thickness = thicknessForPoint(index: 0, total: points.count, velocity: points.last?.velocity ?? 0)

        context.stroke(
            path,
            with: .color(strokeColor),
            style: StrokeStyle(
                lineWidth: thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    // MARK: - Ribbon Drawing

    private func drawRibbon(context: GraphicsContext, points: [TrailPoint]) {
        guard points.count >= 3 else {
            drawLine(context: context, points: points)
            return
        }

        var path = Path()

        // Create a thick bezier path that varies with speed
        for (index, point) in points.enumerated() {
            let thickness = thicknessForPoint(
                index: index,
                total: points.count,
                velocity: point.velocity
            )

            if index == 0 {
                path.move(to: point.position)
            } else {
                let prev = points[index - 1]
                let mid = CGPoint(
                    x: (prev.position.x + point.position.x) / 2,
                    y: (prev.position.y + point.position.y) / 2
                )
                path.addQuadCurve(to: mid, control: prev.position)
            }
        }

        // Stroke with gradient thickness
        let strokeColor = colorForTrail(index: 0, total: points.count)
        context.stroke(
            path,
            with: .color(strokeColor),
            style: StrokeStyle(
                lineWidth: configuration.thickness * 2,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    // MARK: - Glow Effect

    private func drawGlow(context: GraphicsContext, points: [TrailPoint], glow: GlowConfig) {
        let path = createSmoothPath(points: points)
        let glowColor = (glow.color ?? colorForTrail(index: 0, total: points.count))
            .opacity(glow.intensity * 0.3)

        context.addFilter(.blur(radius: glow.radius))
        context.stroke(
            path,
            with: .color(glowColor),
            style: StrokeStyle(
                lineWidth: configuration.thickness + glow.radius,
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.addFilter(.blur(radius: 0)) // Reset
    }

    // MARK: - Particles

    private func drawParticles(context: GraphicsContext, points: [TrailPoint], particles: ParticleConfig) {
        // Sample a subset of points for particle placement
        let stride = max(1, points.count / particles.count)
        for i in stride(to: points.count, step: stride) {
            let point = points[i]
            let offset = CGPoint(
                x: CGFloat.random(in: -particles.size...particles.size),
                y: CGFloat.random(in: -particles.size...particles.size)
            )
            let rect = CGRect(
                x: point.position.x + offset.x - particles.size / 2,
                y: point.position.y + particles.size.y - particles.size / 2,
                width: particles.size,
                height: particles.size
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(particles.color.opacity(0.7))
            )
        }
    }

    // MARK: - Custom Cursor

    private func drawCustomCursor(context: GraphicsContext, at point: TrailPoint) {
        let cursorSize: CGFloat = 8
        let rect = CGRect(
            x: point.position.x - cursorSize / 2,
            y: point.position.y - cursorSize / 2,
            width: cursorSize,
            height: cursorSize
        )

        // Draw a small dot at the cursor position
        context.fill(
            Path(ellipseIn: rect),
            with: .color(.white)
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(.black),
            style: StrokeStyle(lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func createSmoothPath(points: [TrailPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }

        path.move(to: first.position)
        for i in 1..<points.count {
            path.addLine(to: points[i].position)
        }
        return path
    }

    private func colorForTrail(index: Int, total: Int) -> Color {
        switch configuration.color {
        case .solid(let c):
            return c
        case .gradient(let c1, let c2):
            let t = Double(index) / Double(max(total - 1, 1))
            return Color(red: interpolate(c1.red, c2.red, t),
                        green: interpolate(c1.green, c2.green, t),
                        blue: interpolate(c1.blue, c2.blue, t))
        case .rainbow:
            let colors = configuration.color.colors
            let t = Double(index) / Double(max(total - 1, 1))
            let colorIndex = Int(t * Double(colors.count - 1))
            return colors[min(colorIndex, colors.count - 1)]
        }
    }

    private func thicknessForPoint(index: Int, total: Int, velocity: CGFloat) -> CGFloat {
        let baseThickness = configuration.thickness
        let progress = CGFloat(index) / CGFloat(max(total - 1, 1))

        switch configuration.speedMode {
        case .fixed:
            return baseThickness * (1.0 - progress * 0.5)
        case .adaptive:
            let speedFactor = min(velocity / 2000, 1.0) // Normalize velocity
            return baseThickness * (1.0 - progress * 0.5) * (1.0 + speedFactor * 0.5)
        }
    }

    private func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add TrailRenderer with line, ribbon, glow, and particle drawing"
```

---

### Task 8: CursorTrail (Main Entry Point / Builder)

**Files:**
- Create: `cursor trail/Sources/CursorTrail/CursorTrail.swift`

- [ ] **Step 1: Create CursorTrail.swift**

```swift
import Foundation
import QuartzCore
import CoreGraphics

/// Main entry point for the CursorTrail library.
/// Uses the builder pattern for configuration.
///
/// ## Usage
///
/// ```swift
/// import CursorTrail
///
/// // Start a trail with default settings
/// CursorTrail().start()
///
/// // Customize the trail
/// CursorTrail()
///     .color(.gradient(.red, .blue))
///     .thickness(4)
///     .length(150)
///     .style(.ribbon)
///     .glow(GlowConfig(radius: 10, intensity: 0.6))
///     .start()
///
/// // Stop the trail
/// CursorTrail.current?.stop()
/// ```
public final class CursorTrail {
    public static var current: CursorTrail?

    private var configuration: TrailConfiguration
    private var trailWindow: TrailWindow?
    private var displayLink: CVDisplayLink?
    private var trailPoints: RingBuffer<TrailPoint>
    private var lastMouseLocation: CGPoint = .zero
    private var lastTimestamp: CFTimeInterval = 0
    private var isRunning: Bool = false

    // MARK: - Builder

    public init() {
        self.configuration = TrailConfiguration()
        self.trailPoints = RingBuffer(capacity: configuration.length)
    }

    @discardableResult
    public func color(_ color: TrailColor) -> CursorTrail {
        configuration.color = color
        return self
    }

    @discardableResult
    public func thickness(_ thickness: CGFloat) -> CursorTrail {
        configuration.thickness = max(thickness, 1)
        return self
    }

    @discardableResult
    public func length(_ length: Int) -> CursorTrail {
        configuration.length = max(length, 10)
        self.trailPoints = RingBuffer(capacity: configuration.length)
        return self
    }

    @discardableResult
    public func style(_ style: TrailStyle) -> CursorTrail {
        configuration.style = style
        return self
    }

    @discardableResult
    public func speed(_ mode: SpeedMode) -> CursorTrail {
        configuration.speedMode = mode
        return self
    }

    @discardableResult
    public func glow(_ config: GlowConfig) -> CursorTrail {
        configuration.glow = config
        return self
    }

    @discardableResult
    public func particles(_ config: ParticleConfig) -> CursorTrail {
        configuration.particles = config
        return self
    }

    @discardableResult
    public func blur(_ config: BlurConfig) -> CursorTrail {
        configuration.blur = config
        return self
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return false }

        // Check permissions
        guard PermissionsManager.hasAccessibilityPermission else {
            print("CursorTrail: Accessibility permission required. Call PermissionsManager.openAccessibilitySettings()")
            return false
        }

        guard PermissionsManager.hasScreenRecordingPermission else {
            print("CursorTrail: Screen recording permission required. Call PermissionsManager.openScreenRecordingSettings()")
            return false
        }

        // Create overlay window
        let window = TrailWindow()
        self.trailWindow = window

        // Create renderer
        let renderer = TrailRenderer(configuration: configuration)
        window.updateRenderer(renderer)
        window.orderFrontRegardless()

        // Hide system cursor
        CursorManager.hideCursor()

        // Start display link for 60fps updates
        startDisplayLink()

        isRunning = true
        CursorTrail.current = self
        return true
    }

    public func stop() {
        guard isRunning else { return }

        stopDisplayLink()
        CursorManager.showCursor()
        trailWindow?.orderOut(nil)
        trailWindow = nil
        trailPoints.clear()
        isRunning = false
        CursorTrail.current = nil
    }

    // MARK: - Display Link (60fps)

    private func startDisplayLink() {
        let callback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, userInfo) -> CVStatus in
            guard let userInfo = userInfo else { return kCVStatusError }
            let trail = Unmanaged<CursorTrail>.fromOpaque(userInfo).takeUnretainedValue()
            trail.updateTrail()
            return kCVStatusSuccess
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        CVDisplayLinkSetOutputCallback(displayLink!, callback, selfPointer)
        CVDisplayLinkStart(displayLink!)
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            CVDisplayLinkRelease(link)
            displayLink = nil
        }
    }

    private func updateTrail() {
        let currentLocation = CursorManager.currentMouseLocation
        let currentTime = CACurrentMediaTime()

        // Calculate velocity
        let dx = currentLocation.x - lastMouseLocation.x
        let dy = currentLocation.y - lastMouseLocation.y
        let distance = sqrt(dx * dx + dy * dy)
        let dt = currentTime - lastTimestamp
        let velocity = dt > 0 ? CGFloat(distance / dt) : 0

        // Only add point if cursor moved enough (reduces noise)
        guard distance > 1.0 else { return }

        let point = TrailPoint(
            position: currentLocation,
            timestamp: currentTime,
            velocity: velocity
        )

        trailPoints.append(point)
        trailWindow?.updateTrailPoints(trailPoints.toArray())

        lastMouseLocation = currentLocation
        lastTimestamp = currentTime
    }

    // MARK: - Configuration Access

    public var config: TrailConfiguration {
        return configuration
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "feat: add CursorTrail main entry point with builder pattern and 60fps display link"
```

---

### Task 9: README Documentation

**Files:**
- Create: `cursor trail/README.md`

- [ ] **Step 1: Create README.md**

See the full README content below — this is the critical document the user asked for.

```markdown
# CursorTrail

A system-wide macOS library that renders a customizable cursor trail overlay. Replace the system cursor with a smooth, animated trail — distributed as a Swift Package.

## Features

- **Line & Ribbon styles** — smooth paths or thick flowing ribbons
- **Full customization** — color, gradient, rainbow, thickness, length, speed reactivity
- **Optional effects** — glow, particles, blur
- **60fps rendering** — GPU-accelerated via SwiftUI Canvas + CVDisplayLink
- **System-wide** — works across all apps on the system
- **Builder API** — chainable, readable configuration

## Requirements

- macOS 13+
- Xcode 15+
- Accessibility permission (to hide system cursor)
- Screen recording permission (for overlay window)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourname/CursorTrail.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → enter the repo URL.

## Quick Start

```swift
import CursorTrail

// Start with defaults (cyan line, 100 points)
CursorTrail().start()

// Customize
CursorTrail()
    .color(.gradient(.red, .blue))
    .thickness(4)
    .length(150)
    .style(.ribbon)
    .speed(.adaptive)
    .glow(GlowConfig(radius: 10, intensity: 0.6))
    .particles(ParticleConfig(shape: .star, count: 8, lifetime: 1.5))
    .start()

// Stop
CursorTrail.current?.stop()
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────┐
│                  Your App                    │
│                                              │
│   CursorTrail().color(.red).start()         │
│              │                               │
│              ▼                               │
│   ┌──────────────────────┐                  │
│   │   CursorTrail        │ ← Builder API    │
│   │   (main entry point) │                  │
│   └──────────┬───────────┘                  │
│              │                               │
│              ▼                               │
│   ┌──────────────────────┐                  │
│   │   CVDisplayLink      │ ← 60fps timer    │
│   │   (display link)     │                  │
│   └──────────┬───────────┘                  │
│              │                               │
│              ▼                               │
│   ┌──────────────────────┐                  │
│   │   CursorManager      │ ← Hides system   │
│   │   (cursor hide/show) │   cursor         │
│   └──────────┬───────────┘                  │
│              │                               │
│              ▼                               │
│   ┌──────────────────────┐                  │
│   │   TrailWindow        │ ← Transparent    │
│   │   (overlay window)   │   overlay        │
│   └──────────┬───────────┘                  │
│              │                               │
│              ▼                               │
│   ┌──────────────────────┐                  │
│   │   TrailRenderer      │ ← Draws trail    │
│   │   (Canvas drawing)   │   on screen      │
│   └──────────────────────┘                  │
└─────────────────────────────────────────────┘
```

### How Cursor Replacement Works

This is the most important part to understand. Here's exactly how we replace the system cursor:

#### Step 1: Hide the System Cursor

```swift
CGDisplayHideCursor(CGMainDisplayID())
```

This CoreGraphics function hides the cursor for the entire display. It's reference-counted — you must call `CGDisplayShowCursor` the same number of times to show it again. Our `CursorManager` handles this safely.

**Why this works:** macOS continues to track mouse position even when the cursor is hidden. We still receive `mouseMoved` events and can query `NSEvent.mouseLocation`.

#### Step 2: Create a Transparent Overlay Window

We create an `NSWindow` with:
- `styleMask: .borderless` — no title bar or controls
- `isOpaque = false`, `backgroundColor = .clear` — fully transparent
- `ignoresMouseEvents = true` — clicks pass through to apps below
- `level = .screenSaver` — floats above everything including full-screen apps

#### Step 3: Track Mouse Position at 60fps

We use `CVDisplayLink` — a CoreVideo timer synchronized to the display refresh rate. This gives us exactly 60 callbacks per second, one per frame.

On each frame:
1. Read `NSEvent.mouseLocation` (screen coordinates)
2. Calculate velocity from position delta
3. Append a `TrailPoint` to the `RingBuffer`

#### Step 4: Draw the Trail

The `TrailRenderer` draws on a SwiftUI `Canvas`:
- **Line style:** Connects all trail points with a smooth path
- **Ribbon style:** Creates a thick bezier path with variable width
- **Glow:** Adds a blurred stroke behind the main trail
- **Particles:** Draws shapes at sampled points along the trail
- **Custom cursor:** Draws a small dot at the latest position

#### Step 5: Show the Cursor Again

```swift
CGDisplayShowCursor(CGMainDisplayID())
```

When you call `stop()`, the system cursor reappears exactly where it was.

### Permissions

| Permission | Why It's Needed | How to Grant |
|------------|-----------------|--------------|
| Accessibility | Required to call `CGDisplayHideCursor` on macOS 11+ | System Settings → Privacy & Security → Accessibility |
| Screen Recording | Required for the overlay window to appear on screen | System Settings → Privacy & Security → Screen Recording |

The library checks permissions on `start()` and provides clear error messages if denied.

### Performance

- **60fps guaranteed** via `CVDisplayLink` (display-synchronized timer)
- **Ring buffer** for O(1) point append/evict
- **GPU rendering** via SwiftUI Canvas (automatic Metal backend)
- **Minimal CPU usage** when cursor is stationary (skips duplicate positions)
- **Optional effects** (glow, particles, blur) can be enabled independently

### Configuration Reference

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `color` | `TrailColor` | `.solid(.cyan)` | Solid, gradient, or rainbow |
| `thickness` | `CGFloat` | `3` | Line width in points |
| `length` | `Int` | `100` | Trail points retained |
| `style` | `TrailStyle` | `.line` | `.line` or `.ribbon` |
| `speed` | `SpeedMode` | `.adaptive` | `.fixed` or `.adaptive` |
| `glow` | `GlowConfig?` | `nil` | Glow radius and intensity |
| `particles` | `ParticleConfig?` | `nil` | Shape, count, lifetime |
| `blur` | `BlurConfig?` | `nil` | Blur radius |

## Example App

See `Examples/ExampleApp/` for a complete working example.

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
cd "."
git add cursor trail/
git commit -m "docs: add comprehensive README with architecture, cursor replacement explanation, and API reference"
```

---

### Task 10: Final Build & Test

- [ ] **Step 1: Run full build**

Run: `cd "cursor trail" && swift build`
Expected: Build succeeds with no warnings

- [ ] **Step 2: Run all tests**

Run: `cd "cursor trail" && swift test`
Expected: All tests PASS

- [ ] **Step 3: Verify file structure**

Run: `find "cursor trail" -name "*.swift" | sort`
Expected: All 14 source files + 2 test files listed

- [ ] **Step 4: Final commit**

```bash
cd "."
git add cursor trail/
git commit -m "chore: final build verification and test run"
```

---

## Execution Handoff

After saving the plan, offer execution choice:

**Plan complete and saved to `docs/superpowers/plans/2026-06-28-cursor-trail.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
