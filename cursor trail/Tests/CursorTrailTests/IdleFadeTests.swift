import Foundation
import Testing
@testable import CursorTrail

/// Idle-fade arithmetic: when the cursor stops, `fadeSpeed` accumulates and sheds whole
/// points from the head of the ring buffer, carrying the remainder to the next frame.
@Suite("Idle fade math")
struct IdleFadeTests {

    @Test("fadeSpeed below 1.0 sheds nothing but accumulates")
    func slowFadeAccumulatesWithoutShedding() {
        let first = CursorTrail.idleFadeStep(count: 5, accumulator: 0, fadeSpeed: 0.3)
        #expect(first.removed == 0)
        #expect(first.accumulator == 0.3)

        let second = CursorTrail.idleFadeStep(count: 5, accumulator: first.accumulator, fadeSpeed: 0.3)
        #expect(second.removed == 0)
        #expect(second.accumulator == 0.6)
    }

    @Test("accumulator crossing 1.0 sheds exactly one point")
    func crossingOneShedsOnePoint() {
        let step = CursorTrail.idleFadeStep(count: 5, accumulator: 0.8, fadeSpeed: 0.5)

        #expect(step.removed == 1)
        #expect(abs(step.accumulator - 0.3) < 1e-9, "the fraction left over must carry to the next frame")
    }

    @Test("a large fadeSpeed sheds multiple points in one frame")
    func largeFadeShedsSeveral() {
        let step = CursorTrail.idleFadeStep(count: 10, accumulator: 0, fadeSpeed: 2.5)

        #expect(step.removed == 2)
        #expect(step.accumulator == 0.5)
    }

    @Test("never sheds more points than the buffer holds")
    func neverOverRemoves() {
        // fadeSpeed 100 could try to shed 100 points from a 3-point buffer.
        let step = CursorTrail.idleFadeStep(count: 3, accumulator: 0, fadeSpeed: 100)

        #expect(step.removed == 3, "removal must clamp at the buffer's count")
        #expect(step.accumulator >= 0)
    }

    @Test("an empty buffer sheds nothing and resets the accumulator")
    func emptyBufferIsInert() {
        let step = CursorTrail.idleFadeStep(count: 0, accumulator: 0, fadeSpeed: 5)

        #expect(step.removed == 0)
        #expect(step.accumulator == 0, "with no points to shed, the accumulator must not bank credit")
    }

    @Test("the accumulator is clamped so a stopped trail cannot grow it unbounded")
    func accumulatorIsClamped() {
        var accumulator: Double = 0
        var last = CursorTrail.idleFadeStep(count: 1000, accumulator: accumulator, fadeSpeed: 0.1)

        for _ in 0..<500 {
            last = CursorTrail.idleFadeStep(count: 1000, accumulator: last.accumulator, fadeSpeed: 0.1)
            #expect(last.accumulator <= CursorTrail.maxFadeAccumulator)
        }

        accumulator = last.accumulator
        #expect(accumulator <= CursorTrail.maxFadeAccumulator)
        #expect(accumulator >= 0)
    }

    @Test("a full buffer is drained exactly over the frames fadeSpeed implies")
    func bufferDrainsPredictably() {
        // fadeSpeed 1.0 sheds exactly one point per frame.
        var remaining = 4
        var frames = 0

        while remaining > 0, frames < 100 {
            let step = CursorTrail.idleFadeStep(count: remaining, accumulator: 0, fadeSpeed: 1.0)
            remaining -= step.removed
            frames += 1
        }

        #expect(remaining == 0)
        #expect(frames == 4, "four points at one point per frame takes four frames")
    }

    @Test("a fractional fadeSpeed drains at one point per 1/fadeSpeed frames")
    func fractionalFadeDrainRate() {
        // A sub-1.0 fadeSpeed can only cross the 1.0 threshold once per frame, and it
        // takes 1/fadeSpeed frames of banking to get there. 0.25 => one point every 4
        // frames, so 10 points take 40 frames.
        var remaining = 10
        var accumulator: Double = 0
        var frames = 0

        while remaining > 0, frames < 1000 {
            let step = CursorTrail.idleFadeStep(count: remaining, accumulator: accumulator, fadeSpeed: 0.25)
            #expect(step.removed <= 1, "a sub-1.0 fadeSpeed can never shed more than one point")
            remaining -= step.removed
            accumulator = step.accumulator
            frames += 1
        }

        #expect(remaining == 0)
        #expect(frames == 40, "10 points at one point per 4 frames takes 40 frames")
    }

    @Test("fadeSpeed of 1.0 or more drains faster than one point per frame")
    func fastFadeDrainsMultiplePerFrame() {
        var remaining = 12
        var accumulator: Double = 0
        var frames = 0

        while remaining > 0, frames < 100 {
            let step = CursorTrail.idleFadeStep(count: remaining, accumulator: accumulator, fadeSpeed: 2.0)
            remaining -= step.removed
            accumulator = step.accumulator
            frames += 1
        }

        #expect(remaining == 0)
        #expect(frames == 6, "12 points at 2 per frame takes 6 frames")
    }

    @Test("the accumulator carries across frames so a fractional fade still drains")
    func accumulatorCarryMakesDrainPossible() {
        // fadeSpeed 0.3 never reaches 1.0 in a single frame; it can only drain because the
        // remainder is carried into the next frame. Resetting it each frame would stall.
        var remaining = 4
        var accumulator: Double = 0
        var frames = 0

        while remaining > 0, frames < 100 {
            let step = CursorTrail.idleFadeStep(count: remaining, accumulator: accumulator, fadeSpeed: 0.3)
            remaining -= step.removed
            accumulator = step.accumulator
            frames += 1
        }

        #expect(remaining == 0, "the carried accumulator must eventually shed every point")
        #expect(frames == 14, "four points at ~0.3 per frame takes 14 frames")
    }
}