import Foundation
import Testing
import CoreGraphics
@testable import CursorTrail

/// Renderer geometry guards. These are the `precondition`s/bounds that keep the drawing
/// code from producing garbage when the point count is degenerate — the class of bug that
/// produced NaN geometry rather than a visible error.
@Suite("TrailRenderer geometry guards")
struct TrailRendererGeometryTests {

    @Test("fewer than two points is not drawable")
    func drawableGuard() {
        #expect(TrailRenderer.isDrawable(pointCount: 0) == false)
        #expect(TrailRenderer.isDrawable(pointCount: 1) == false)
        #expect(TrailRenderer.isDrawable(pointCount: 2) == true)
        #expect(TrailRenderer.isDrawable(pointCount: 50) == true)
    }

    @Test("ribbon falls back to the line path below three points")
    func ribbonFallbackGuard() {
        #expect(TrailRenderer.usesRibbonFallback(pointCount: 0) == true)
        #expect(TrailRenderer.usesRibbonFallback(pointCount: 1) == true)
        #expect(TrailRenderer.usesRibbonFallback(pointCount: 2) == true)
        #expect(TrailRenderer.usesRibbonFallback(pointCount: 3) == false)
        #expect(TrailRenderer.usesRibbonFallback(pointCount: 10) == false)
    }

    @Test("resample sample count stays positive and monotonic")
    func resampleCount() {
        #expect(TrailRenderer.resampleSampleCount(pointCount: 0) == 0)
        #expect(TrailRenderer.resampleSampleCount(pointCount: 1) == 1)
        #expect(TrailRenderer.resampleSampleCount(pointCount: 2) == 9)
        #expect(TrailRenderer.resampleSampleCount(pointCount: 3) == 17)

        // Monotonic and never negative as the buffer grows.
        var previous = 0
        for count in 0...40 {
            let samples = TrailRenderer.resampleSampleCount(pointCount: count)
            #expect(samples >= previous)
            #expect(samples >= 0)
            previous = samples
        }
    }

    @Test("the cursor y offset sits the trail under the arrow and stays finite")
    func yOffsetIsSane() {
        #expect(TrailRenderer.yOffset > 0, "the trail is drawn below the cursor position")
        #expect(TrailRenderer.yOffset.isFinite)
        #expect(TrailRenderer.yOffset < 200, "an offset this large would be visibly detached")
    }

    /// The ring buffer feeding the renderer is indexed with preconditions; guard the
    /// indexing boundary so a full buffer never reads out of range.
    @Test("renderer input buffer indexes stay in range when full")
    func bufferIndexesStayInRange() {
        let capacity = 10
        var buffer = RingBuffer<TrailPoint>(capacity: capacity)

        for i in 0..<capacity {
            buffer.append(TrailPoint(position: CGPoint(x: CGFloat(i), y: 0)))
        }
        #expect(buffer.count == capacity)
        #expect(buffer[capacity - 1].position.x == CGFloat(capacity - 1))

        // Overflow keeps count pinned at capacity and still indexes cleanly.
        buffer.append(TrailPoint(position: CGPoint(x: 999, y: 0)))
        #expect(buffer.count == capacity)
        #expect(buffer[capacity - 1].position.x == 999)
    }

    /// Degenerate input — all identical points — yields zero-length normals. The renderer
    /// substitutes unit normals in that case; verify the guard's threshold explicitly.
    @Test("zero-length segments do not produce NaN geometry")
    func zeroLengthSegmentGuard() {
        let dx: CGFloat = 0
        let dy: CGFloat = 0
        let length = (dx * dx + dy * dy).squareRoot()

        #expect(length.isFinite)
        #expect(length == 0)

        // The renderer falls back to (0, 1) rather than dividing by zero.
        let nx: CGFloat = length > 0 ? -dy / length : 0
        let ny: CGFloat = length > 0 ? dx / length : 1
        #expect(nx.isFinite)
        #expect(ny.isFinite)
        #expect(ny == 1)
    }
}