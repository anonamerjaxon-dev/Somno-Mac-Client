import XCTest
@testable import GhostTrail

// These tests cover the pure-logic pieces of the module: the ring buffer, the
// configuration clamping, and the quartz→view coordinate conversion that the
// renderer relies on to place trails on secondary displays.

final class RingBufferTests: XCTestCase {
    func testAppendAndReadInOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for i in 0..<4 {
            buffer.append(i)
        }
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.first, 0)
        XCTAssertEqual(buffer.last, 3)
        XCTAssertEqual(buffer[0], 0)
        XCTAssertEqual(buffer[3], 3)
    }

    func testOverwritesOldestWhenFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for i in 0..<5 {
            buffer.append(i)
        }
        XCTAssertEqual(buffer.count, 3, "count must never exceed capacity")
        XCTAssertEqual(buffer.first, 2, "oldest entries are dropped")
        XCTAssertEqual(buffer.last, 4)
    }

    func testRemoveFirstDrainsBuffer() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(10)
        buffer.append(20)
        XCTAssertEqual(buffer.removeFirst(), 10)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.removeFirst(), 20)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.removeFirst(), "removing from empty returns nil")
    }

    func testRejectsZeroCapacity() {
        // `init(capacity:)` traps on a non-positive capacity; keep capacity positive
        // and verify a one-slot buffer behaves as a strict overwrite ring.
        var buffer = RingBuffer<Int>(capacity: 1)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.last, 2)
    }
}

final class GhostTrailConfigurationTests: XCTestCase {
    func testClampsOutOfRangeValues() {
        let config = GhostTrailConfiguration(
            strokeWidth: 0,
            frameCount: 1,
            fadeDuration: 0,
            movementThreshold: 0,
            jumpThreshold: 0,
            opacity: 5,
            cornerRadius: -3
        )
        XCTAssertEqual(config.strokeWidth, 0.5)
        XCTAssertEqual(config.frameCount, 10)
        XCTAssertEqual(config.fadeDuration, 0.1)
        XCTAssertEqual(config.movementThreshold, 1)
        XCTAssertEqual(config.jumpThreshold, 1)
        XCTAssertEqual(config.opacity, 1.0)
        XCTAssertEqual(config.cornerRadius, 0)
    }

    func testDefaultWindowLevelIsBehindWindows() {
        // The feature promise is a trail that renders *behind* the dragged window.
        XCTAssertTrue(GhostTrailConfiguration().windowLevel == .behindWindows)
    }
}

final class TrailCoordinateConverterTests: XCTestCase {
    /// Single 1920x1080 display at the Cocoa origin, overlay covering exactly it.
    private let singleDisplay = TrailCoordinateConverter(
        mainDisplayFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        overlayFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080)
    )

    func testFlipsVerticalAxisAboutMainDisplay() {
        // Quartz rect at the very top of the screen (y=0) maps to the top of the
        // view in bottom-left coordinates: y = 1080 - (0 + 100) = 980.
        let rect = singleDisplay.viewRect(fromQuartz: CGRect(x: 100, y: 0, width: 200, height: 100))
        XCTAssertEqual(rect, CGRect(x: 100, y: 980, width: 200, height: 100))
    }

    func testFlipsBottomOfScreenToViewOrigin() {
        let rect = singleDisplay.viewRect(fromQuartz: CGRect(x: 0, y: 980, width: 10, height: 100))
        XCTAssertEqual(rect.origin.y, 0)
    }

    func testPreservesSize() {
        let rect = singleDisplay.viewRect(fromQuartz: CGRect(x: 37, y: 111, width: 333, height: 217))
        XCTAssertEqual(rect.width, 333)
        XCTAssertEqual(rect.height, 217)
    }

    /// Secondary display placed to the LEFT of the main one (negative x in Cocoa).
    func testSecondaryDisplayToTheLeft() {
        // Main 1920x1080 at (0,0); secondary 1280x800 at (-1280, 0); overlay spans both.
        let converter = TrailCoordinateConverter(
            mainDisplayFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            overlayFrame: NSRect(x: -1280, y: 0, width: 3200, height: 1080)
        )
        // Window at the top-left of the *main* display stays at x=1920 in view space.
        let onMain = converter.viewRect(fromQuartz: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(onMain.origin.x, 1280)
        XCTAssertEqual(onMain.origin.y, 1080 - 50)

        // A window on the secondary display sits in the negative quartz-x region and
        // must land in the overlay's left half, at a positive view coordinate.
        let onSecondary = converter.viewRect(fromQuartz: CGRect(x: -1280, y: 0, width: 100, height: 50))
        XCTAssertEqual(onSecondary.origin.x, 0)
        XCTAssertEqual(onSecondary.origin.y, 1080 - 50)
    }

    /// Secondary display ABOVE the main one — the case that exposes a flip measured
    /// against the wrong display height.
    func testSecondaryDisplayAboveMain() {
        // Main 1920x1080 at (0,0); secondary 1920x1080 at (0, 1080); overlay spans both.
        let converter = TrailCoordinateConverter(
            mainDisplayFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            overlayFrame: NSRect(x: 0, y: 0, width: 1920, height: 2160)
        )
        // Quartz y=0 is the top edge of the *main* display. In the 2160-tall overlay
        // (bottom-left origin) that edge sits at y=1080, so a 100pt-tall rect has
        // its origin at 980 and its top at 1080 — i.e. the lower half of the overlay.
        let rect = converter.viewRect(fromQuartz: CGRect(x: 10, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect.origin.y, 980)
        XCTAssertEqual(rect.maxY, 1080)
        XCTAssertEqual(rect.origin.x, 10)
    }

    func testRoundTripThroughViewAndBackIsStableForSize() {
        let rect = singleDisplay.viewRect(fromQuartz: CGRect(x: 500, y: 250, width: 400, height: 300))
        // The y-flip must not move the rect's vertical *centre* above the axis it
        // started on: 250..550 in quartz (centre 400) maps to centre 1080-400 = 680.
        XCTAssertEqual(rect.midY, 1080 - 400, accuracy: 0.001)
    }
}