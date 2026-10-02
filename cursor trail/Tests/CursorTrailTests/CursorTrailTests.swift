import Foundation
import Testing
import AppKit
@testable import CursorTrail

/// Lifecycle: start / stop / double-start, plus the ownership contract that a dropped
/// reference really stops the trail.
///
/// These drive the real `CursorTrail`, which needs an `NSWindow`, so they are pinned to
/// the main actor: `start()`/`stop()` assert `dispatchPrecondition(condition: .onQueue(.main))`.
@Suite("CursorTrail lifecycle")
struct CursorTrailLifecycleTests {

    @Test("start() activates the trail and publishes it as current")
    @MainActor
    func startActivatesTrail() {
        let trail = CursorTrail()

        #expect(trail.isActive == false)
        #expect(trail.start() == true)
        #expect(trail.isActive == true)
        #expect(CursorTrail.current === trail)

        trail.stop()
    }

    @Test("double start() is a no-op that reports false")
    @MainActor
    func doubleStartIsNoOp() {
        let trail = CursorTrail()

        #expect(trail.start() == true)
        #expect(trail.start() == false, "start() must refuse to run twice")
        #expect(trail.isActive == true)
        #expect(CursorTrail.current === trail)

        trail.stop()
    }

    @Test("stop() tears down and clears current")
    @MainActor
    func stopClearsState() {
        let trail = CursorTrail()
        #expect(trail.start() == true)

        trail.stop()

        #expect(trail.isActive == false)
        #expect(CursorTrail.current == nil)
    }

    @Test("stop() is safe to call twice")
    @MainActor
    func stopIsIdempotent() {
        let trail = CursorTrail()
        #expect(trail.start() == true)

        trail.stop()
        trail.stop()

        #expect(trail.isActive == false)
        #expect(CursorTrail.current == nil)
    }

    @Test("stopping an instance that never started does not clear another trail's current")
    @MainActor
    func stopOnIdleInstanceDoesNotClearCurrent() {
        let running = CursorTrail()
        #expect(running.start() == true)

        let idle = CursorTrail()
        idle.stop()

        #expect(CursorTrail.current === running, "stop() must only clear current when current === self")

        running.stop()
    }

    @Test("starting a second trail stops the first — single active trail")
    @MainActor
    func secondStartStopsPrevious() {
        let first = CursorTrail()
        let second = CursorTrail()

        #expect(first.start() == true)
        #expect(first.isActive == true)

        #expect(second.start() == true)

        #expect(first.isActive == false, "the previous instance must be stopped by a new start()")
        #expect(second.isActive == true)
        #expect(CursorTrail.current === second)

        second.stop()
    }

    /// H1 regression: the trail must not retain itself through `CursorTrail.current`.
    /// The old code used `Unmanaged.passRetained(self)` for the display link AND a
    /// strong static `current`, so `deinit { stop() }` never ran and the overlay
    /// became unstoppable. Dropping the last strong reference must now stop it.
    @Test("dropping the last reference stops the trail (no zombie overlay)")
    @MainActor
    func droppingLastReferenceStopsTrail() {
        weak var weakTrail: CursorTrail?

        autoreleasepool {
            let trail = CursorTrail()
            weakTrail = trail
            #expect(trail.start() == true)
            #expect(trail.isActive == true)
            // `trail` goes out of scope here; nothing else owns it.
        }

        #expect(weakTrail == nil, "CursorTrail must not be kept alive by its own display link or static")
        #expect(CursorTrail.current == nil, "current must be weak, so a dropped trail stops")
    }
}