import Foundation
import Testing
import CoreGraphics
@testable import CursorTrail

/// H2: converting a global mouse location into overlay-window local space.
///
/// The old code did `y = NSScreen.main!.frame.height - y` and kept x untouched, which
/// ignored the screen origin entirely — on a secondary display every point landed in the
/// wrong place. The fix mirrors y about `screenFrame.maxY` and subtracts
/// `screenFrame.origin`. These are pure-math tests: no real screens are involved.
@Suite("Multi-display coordinate flip")
struct CoordinateFlipTests {

    /// Primary display at the desktop origin: origin offset is zero, so this reduces to
    /// the old behaviour and must stay exact.
    @Test("primary display at origin keeps the legacy result")
    func primaryDisplayAtOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let result = CursorTrail.localPoint(fromGlobal: CGPoint(x: 100, y: 200), screenFrame: screen)

        #expect(result == CGPoint(x: 100, y: 880))
    }

    /// A display to the RIGHT of the primary: global x carries the screen's origin, so
    /// the local x must be shifted back to zero-based.
    @Test("secondary display to the right subtracts its origin x")
    func secondaryDisplayToTheRight() {
        let screen = CGRect(x: 1920, y: 0, width: 1280, height: 900)

        let result = CursorTrail.localPoint(fromGlobal: CGPoint(x: 2000, y: 450), screenFrame: screen)

        #expect(result == CGPoint(x: 80, y: 450))
    }

    /// A display ABOVE the primary. In AppKit's bottom-left-origin global space the
    /// screen's origin.y is the distance from the desktop bottom, and maxY is the
    /// desktop top. Flipping about maxY is what keeps the point inside the window.
    @Test("secondary display above the primary flips about the shared top edge")
    func secondaryDisplayAbovePrimary() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen = CGRect(x: 0, y: 1080, width: 1920, height: 1200)

        // Top-left corner of the upper screen.
        let topLeft = CursorTrail.localPoint(fromGlobal: CGPoint(x: 0, y: 2280), screenFrame: screen)
        #expect(topLeft == CGPoint(x: 0, y: 0))

        // Bottom-left corner: global y = screen.origin.y → local y = screen height.
        let bottomLeft = CursorTrail.localPoint(fromGlobal: CGPoint(x: 0, y: 1080), screenFrame: screen)
        #expect(bottomLeft == CGPoint(x: 0, y: 1200))

        #expect(primary.height == 1080)
    }

    @Test("screen corners map to the full local extent")
    func cornersMapToFullExtent() {
        let screen = CGRect(x: 1440, y: -900, width: 2560, height: 1440)

        let topLeft = CursorTrail.localPoint(fromGlobal: CGPoint(x: 1440, y: 540), screenFrame: screen)
        let bottomRight = CursorTrail.localPoint(fromGlobal: CGPoint(x: 4000, y: -900), screenFrame: screen)

        #expect(topLeft == CGPoint(x: 0, y: 0))
        #expect(bottomRight == CGPoint(x: 2560, y: 1440))
    }

    /// The flip must use the *overlay's* screen height, not the main screen's. These two
    /// disagree on a secondary display, which was the original bug.
    @Test("flip differs from the old main-screen-height formula on a secondary display")
    func differsFromOldMainScreenFormula() {
        let screen = CGRect(x: 1920, y: 0, width: 1280, height: 900)
        let mainScreenHeight: CGFloat = 1080
        let global = CGPoint(x: 2500, y: 300)

        let fixed = CursorTrail.localPoint(fromGlobal: global, screenFrame: screen)
        let old = CGPoint(x: global.x, y: mainScreenHeight - global.y)

        #expect(fixed != old, "the old formula must not match once the screen origin is honoured")
        #expect(fixed == CGPoint(x: 580, y: 600))
    }

    /// Round-trip: global → local → global recovers the original point, so the transform
    /// introduces no drift regardless of screen layout.
    @Test("local to global round-trips")
    func roundTrip() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1280, height: 900),
            CGRect(x: 0, y: 1080, width: 1920, height: 1200),
            CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        ]
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1920, y: 1080),
            CGPoint(x: -1280, y: 640),
            CGPoint(x: 3321.5, y: -87.25)
        ]

        for screen in screens {
            for point in points {
                let local = CursorTrail.localPoint(fromGlobal: point, screenFrame: screen)
                let back = CGPoint(x: local.x + screen.origin.x, y: screen.maxY - local.y)
                #expect(back == point)
            }
        }
    }

    /// A local point must always stay within the overlay window's bounds.
    @Test("local points stay inside the overlay bounds")
    func localPointsStayInBounds() {
        let screen = CGRect(x: 1920, y: 0, width: 1280, height: 900)

        for x in stride(from: 1920.0, through: 3200.0, by: 64) {
            for y in stride(from: 0.0, through: 900.0, by: 45) {
                let local = CursorTrail.localPoint(fromGlobal: CGPoint(x: x, y: y), screenFrame: screen)
                #expect(local.x >= 0 && local.x <= screen.width)
                #expect(local.y >= 0 && local.y <= screen.height)
            }
        }
    }
}