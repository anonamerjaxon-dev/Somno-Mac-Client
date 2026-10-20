import XCTest
import CoreGraphics
@testable import DesktopCanvas

/// Covers `SnapEngine`, which used to live in the demo app and therefore had no
/// tests at all.
final class SnapEngineTests: XCTestCase {

    // MARK: - Helpers

    private func goLCanvas(frame: CGRect, cellSize: Int = 8, id: UUID = UUID()) -> CanvasModel {
        CanvasModel(
            id: id,
            type: .gameOfLife,
            frame: frame,
            gameOfLifeConfig: GameOfLifeConfig(cellSize: cellSize)
        )
    }

    private func videoCanvas(frame: CGRect, naturalSize: CGSize?, id: UUID = UUID()) -> CanvasModel {
        CanvasModel(
            id: id,
            type: .video,
            frame: frame,
            videoConfig: VideoConfig(naturalSize: naturalSize)
        )
    }

    private func engine(
        gridSize: CGFloat = 10,
        screenEdges: Bool = false,
        canvasEdges: Bool = false,
        grid: Bool = false,
        screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 1000),
        others: [(UUID, CGRect)] = [],
        margin: CGFloat = 0
    ) -> SnapEngine {
        SnapEngine(
            gridSize: gridSize,
            snapToScreenEdges: screenEdges,
            snapToCanvasEdges: canvasEdges,
            snapToGrid: grid,
            screenFrame: screenFrame,
            otherCanvases: others.map { (id: $0.0, frame: $0.1) },
            margin: margin
        )
    }

    // MARK: - Move snapping

    func testSnapRectPullsLeftEdgeToScreenEdge() {
        let e = engine(screenEdges: true)
        let result = e.snapRect(CGRect(x: 3, y: 400, width: 100, height: 100))
        XCTAssertEqual(result.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 400, accuracy: 0.001)
    }

    func testSnapRectPullsRightEdgeToScreenEdgeShiftingOrigin() {
        let e = engine(screenEdges: true)
        // maxX = 997 is 3 away from the screen's maxX of 1000, so the origin
        // must move left by the rect's width to keep the right edge on target.
        let result = e.snapRect(CGRect(x: 897, y: 400, width: 100, height: 100))
        XCTAssertEqual(result.origin.x, 900, accuracy: 0.001)
    }

    func testSnapRectPullsToAnotherCanvasEdge() {
        let other = UUID()
        let e = engine(canvasEdges: true, others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))])
        let result = e.snapRect(CGRect(x: 404, y: 300, width: 50, height: 50))
        XCTAssertEqual(result.origin.x, 400, accuracy: 0.001)
    }

    func testSnapRectAlignsRightEdgeToOtherCanvas() {
        let other = UUID()
        let e = engine(canvasEdges: true, others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))])
        let result = e.snapRect(CGRect(x: 352, y: 300, width: 50, height: 50))
        XCTAssertEqual(result.origin.x, 350, accuracy: 0.001)
    }

    func testSnapRectIgnoresExcludedCanvas() {
        let other = UUID()
        let e = engine(canvasEdges: true, others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))])
        let result = e.snapRect(CGRect(x: 404, y: 300, width: 50, height: 50), excluding: other)
        XCTAssertEqual(result.origin.x, 404, accuracy: 0.001)
    }

    func testSnapRectLeavesDistantRectAlone() {
        let e = engine(screenEdges: true)
        let result = e.snapRect(CGRect(x: 250, y: 300, width: 100, height: 100))
        XCTAssertEqual(result.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 300, accuracy: 0.001)
    }

    func testSnapRectSnapsToGridLines() {
        let e = engine(gridSize: 10, grid: true)
        let result = e.snapRect(CGRect(x: 23, y: 47, width: 20, height: 20))
        XCTAssertEqual(result.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 50, accuracy: 0.001)
    }

    // MARK: - Size snapping

    func testSnapSizeRoundsToCellMultiples() {
        let e = engine()
        let size = e.snapSize(CGSize(width: 203, height: 117), for: goLCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        XCTAssertEqual(size.width, 200, accuracy: 0.001)
        XCTAssertEqual(size.height, 120, accuracy: 0.001)
    }

    func testSnapSizeEnforcesMinimumTenCells() {
        let e = engine()
        let size = e.snapSize(CGSize(width: 10, height: 10), for: goLCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        XCTAssertEqual(size.width, 80, accuracy: 0.001)
        XCTAssertEqual(size.height, 80, accuracy: 0.001)
    }

    func testSnapSizeLeavesNonGoLCanvasAlone() {
        let e = engine()
        let canvas = videoCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 200), naturalSize: nil)
        let size = e.snapSize(CGSize(width: 203, height: 117), for: canvas)
        XCTAssertEqual(size.width, 203, accuracy: 0.001)
        XCTAssertEqual(size.height, 117, accuracy: 0.001)
    }

    func testSnapResizeSizeMatchesOtherCanvasDimensions() {
        let other = UUID()
        let e = engine(canvasEdges: true, others: [(other, CGRect(x: 0, y: 0, width: 300, height: 150))])
        let canvas = goLCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let size = e.snapResizeSize(CGSize(width: 303, height: 148), canvasID: canvas.id, canvas: canvas)
        XCTAssertEqual(size.width, 300, accuracy: 0.001)
        XCTAssertEqual(size.height, 150, accuracy: 0.001)
    }

    // MARK: - Corner resize anchoring

    func testTopLeftCornerResizeAnchorsBottomRight() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .topLeft,
            target: CGPoint(x: 150, y: 150),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(result.maxY, 300, accuracy: 0.001)
        XCTAssertEqual(result.width, 152, accuracy: 0.001)
        XCTAssertEqual(result.height, 152, accuracy: 0.001)
    }

    func testBottomRightCornerResizeAnchorsTopLeft() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 250, y: 250),
            canvas: canvas
        )
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
        XCTAssertEqual(result.minY, 100, accuracy: 0.001)
        XCTAssertEqual(result.width, 152, accuracy: 0.001)
        XCTAssertEqual(result.height, 152, accuracy: 0.001)
    }

    // MARK: - Edge resize (previously a silent no-op)

    func testRightEdgeResizeChangesWidthOnly() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .right,
            target: CGPoint(x: 350, y: 500),
            canvas: canvas
        )
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
        XCTAssertEqual(result.minY, 100, accuracy: 0.001)
        XCTAssertEqual(result.height, 200, accuracy: 0.001)
        XCTAssertEqual(result.width, 248, accuracy: 0.001)
    }

    func testBottomEdgeResizeChangesHeightOnly() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottom,
            target: CGPoint(x: 500, y: 350),
            canvas: canvas
        )
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
        XCTAssertEqual(result.minY, 100, accuracy: 0.001)
        XCTAssertEqual(result.width, 200, accuracy: 0.001)
        XCTAssertEqual(result.height, 248, accuracy: 0.001)
    }

    func testLeftEdgeResizeKeepsRightEdgeAnchored() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .left,
            target: CGPoint(x: 150, y: 0),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(result.height, 200, accuracy: 0.001)
        XCTAssertEqual(result.width, 152, accuracy: 0.001)
    }

    func testTopEdgeResizeKeepsBottomEdgeAnchored() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .top,
            target: CGPoint(x: 0, y: 150),
            canvas: canvas
        )
        XCTAssertEqual(result.maxY, 300, accuracy: 0.001)
        XCTAssertEqual(result.width, 200, accuracy: 0.001)
        XCTAssertEqual(result.height, 152, accuracy: 0.001)
    }

    func testEdgeResizeRespectsMinimumExtent() {
        let e = engine()
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .right,
            target: CGPoint(x: 101, y: 0),
            canvas: canvas
        )
        // minExtent is 10 cells = 80pt, and snapSize floors the result there.
        XCTAssertEqual(result.width, 80, accuracy: 0.001)
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
    }

    // MARK: - Video aspect resize (previously never snapped)

    func testVideoCornerResizePreservesAspectRatio() {
        let e = engine(screenEdges: true)
        let canvas = videoCanvas(
            frame: CGRect(x: 100, y: 100, width: 200, height: 200),
            naturalSize: CGSize(width: 400, height: 200) // 2:1
        )
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 700, y: 500),
            canvas: canvas
        )
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
        XCTAssertEqual(result.minY, 100, accuracy: 0.001)
        XCTAssertEqual(result.width, 600, accuracy: 0.001)
        XCTAssertEqual(result.height, 300, accuracy: 0.001)
    }

    func testVideoCornerResizeSnapsDraggedEdgeToScreenEdge() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = videoCanvas(
            frame: CGRect(x: 100, y: 100, width: 200, height: 200),
            naturalSize: CGSize(width: 400, height: 200) // 2:1
        )
        // Cursor is 3pt short of the screen's right edge; the snap must close the
        // gap and the height must follow the locked ratio.
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 997, y: 500),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 1000, accuracy: 0.001)
        XCTAssertEqual(result.width, 900, accuracy: 0.001)
        XCTAssertEqual(result.height, 450, accuracy: 0.001)
    }

    func testVideoTopHandleDerivesWidthFromHeight() {
        let e = engine()
        let canvas = videoCanvas(
            frame: CGRect(x: 100, y: 100, width: 200, height: 200),
            naturalSize: CGSize(width: 400, height: 200) // 2:1
        )
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .top,
            target: CGPoint(x: 0, y: 400),
            canvas: canvas
        )
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
        XCTAssertEqual(result.maxY, 300, accuracy: 0.001)
        XCTAssertEqual(result.height, 50, accuracy: 0.001)
        XCTAssertEqual(result.width, 100, accuracy: 0.001)
    }

    // MARK: - Axis independence
    //
    // Regression: x and y targets used to share one flat list, so an edge could
    // snap to a number that belonged to the other axis. On a 1920x1080 display
    // that pulled canvases onto the screen's horizontal midline (960) or its
    // vertical midline (1080) with nothing on screen to explain the jump.

    func testDoesNotSnapAYValueToTheScreensHorizontalMidline() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = e.snapRect(CGRect(x: 500, y: 957, width: 100, height: 100))
        XCTAssertEqual(result.origin.y, 957, accuracy: 0.001)
    }

    func testDoesNotSnapAnXValueToTheScreensVerticalMidline() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = e.snapRect(CGRect(x: 1077, y: 300, width: 100, height: 100))
        XCTAssertEqual(result.origin.x, 1077, accuracy: 0.001)
    }

    func testDoesNotSnapAYValueToAnotherCanvasXEdge() {
        let other = UUID()
        let e = engine(canvasEdges: true, others: [(other, CGRect(x: 1000, y: 500, width: 100, height: 100))])
        let result = e.snapRect(CGRect(x: 200, y: 996, width: 50, height: 50))
        XCTAssertEqual(result.origin.y, 996, accuracy: 0.001)
    }

    // MARK: - Margin adjacency
    //
    // Regression: `margin` was stored but never read by the engine, while the
    // editor's guide overlay did honour it — so a guide appeared for a snap that
    // never happened.

    func testSnapsToTheMarginGapRightOfAnotherCanvas() {
        let other = UUID()
        let e = engine(canvasEdges: true,
                       others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))],
                       margin: 12)
        let result = e.snapRect(CGRect(x: 515, y: 300, width: 50, height: 50))
        XCTAssertEqual(result.origin.x, 512, accuracy: 0.001) // 400 + 100 + 12
    }

    func testSnapsToTheMarginGapLeftOfAnotherCanvas() {
        let other = UUID()
        let e = engine(canvasEdges: true,
                       others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))],
                       margin: 12)
        let result = e.snapRect(CGRect(x: 336, y: 300, width: 50, height: 50))
        XCTAssertEqual(result.maxX, 388, accuracy: 0.001) // 400 - 12
    }

    func testFlushAlignmentStillOfferedWhenAMarginIsConfigured() {
        let other = UUID()
        let e = engine(canvasEdges: true,
                       others: [(other, CGRect(x: 400, y: 0, width: 100, height: 100))],
                       margin: 12)
        let result = e.snapRect(CGRect(x: 502, y: 300, width: 50, height: 50))
        XCTAssertEqual(result.origin.x, 500, accuracy: 0.001) // flush edge-to-edge
    }

    // MARK: - Resize snapping
    //
    // Regression: only the aspect-locked video path ever consulted screen and
    // canvas edges. A Game of Life corner only grid-rounded, so it could never be
    // dragged flush to a screen edge.

    func testCornerResizeSnapsTheDraggedEdgeToAScreenEdge() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 997, y: 500),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 1000, accuracy: 0.001)
        XCTAssertEqual(result.minX, 100, accuracy: 0.001)
    }

    func testSnappedResizeEdgeIsNotRoundedBackOntoACellBoundary() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200), cellSize: 8)
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 997, y: 500),
            canvas: canvas
        )
        // 900 is not a multiple of 8, but the user aimed at the screen edge;
        // honouring the snap beats landing on a whole number of cells.
        XCTAssertEqual(result.width, 900, accuracy: 0.001)
    }

    func testEdgeResizeSnapsTheSteeredEdgeToAScreenEdge() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .right,
            target: CGPoint(x: 997, y: 0),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 1000, accuracy: 0.001)
        XCTAssertEqual(result.height, 200, accuracy: 0.001)
    }

    func testCornerResizeFallsBackToTheGridWhenNoEdgeIsNear() {
        let e = engine(gridSize: 10, grid: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = goLCanvas(frame: CGRect(x: 100, y: 100, width: 200, height: 200), cellSize: 8)
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottomRight,
            target: CGPoint(x: 247, y: 247),
            canvas: canvas
        )
        XCTAssertEqual(result.maxX, 250, accuracy: 0.001)
    }

    func testVideoTopHandleSnapsItsMinYToTheScreenOrigin() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = videoCanvas(
            frame: CGRect(x: 100, y: 100, width: 200, height: 200),
            naturalSize: CGSize(width: 400, height: 200) // 2:1
        )
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .top,
            target: CGPoint(x: 0, y: 3),
            canvas: canvas
        )
        XCTAssertEqual(result.minY, 0, accuracy: 0.001)
        XCTAssertEqual(result.height, 300, accuracy: 0.001)
        XCTAssertEqual(result.width, 600, accuracy: 0.001)
    }

    func testVideoBottomHandleSnapsItsMaxYToTheScreenTop() {
        let e = engine(screenEdges: true, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let canvas = videoCanvas(
            frame: CGRect(x: 100, y: 100, width: 200, height: 200),
            naturalSize: CGSize(width: 400, height: 200) // 2:1
        )
        let result = e.snapCornerResize(
            rect: CGRect(x: 100, y: 100, width: 200, height: 200),
            handle: .bottom,
            target: CGPoint(x: 0, y: 997),
            canvas: canvas
        )
        XCTAssertEqual(result.maxY, 1000, accuracy: 0.001)
        XCTAssertEqual(result.height, 900, accuracy: 0.001)
        XCTAssertEqual(result.width, 1800, accuracy: 0.001)
    }

    // MARK: - Handle geometry

    func testCornerHandlesExcludeEdges() {
        XCTAssertEqual(Set(ResizeHandle.corners), Set([.topLeft, .topRight, .bottomLeft, .bottomRight]))
        XCTAssertEqual(Set(ResizeHandle.edges), Set([.top, .left, .right, .bottom]))
        XCTAssertEqual(ResizeHandle.allCases.count, 8)
    }

    func testHandlePointsMapToRectPositions() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 60)
        XCTAssertEqual(ResizeHandle.topLeft.point(in: rect), CGPoint(x: 10, y: 20))
        XCTAssertEqual(ResizeHandle.top.point(in: rect), CGPoint(x: 60, y: 20))
        XCTAssertEqual(ResizeHandle.topRight.point(in: rect), CGPoint(x: 110, y: 20))
        XCTAssertEqual(ResizeHandle.right.point(in: rect), CGPoint(x: 110, y: 50))
        XCTAssertEqual(ResizeHandle.bottomRight.point(in: rect), CGPoint(x: 110, y: 80))
        XCTAssertEqual(ResizeHandle.bottom.point(in: rect), CGPoint(x: 60, y: 80))
        XCTAssertEqual(ResizeHandle.bottomLeft.point(in: rect), CGPoint(x: 10, y: 80))
        XCTAssertEqual(ResizeHandle.left.point(in: rect), CGPoint(x: 10, y: 50))
    }
}
