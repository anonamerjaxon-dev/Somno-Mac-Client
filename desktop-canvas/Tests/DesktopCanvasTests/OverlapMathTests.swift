import XCTest
@testable import DesktopCanvas

final class OverlapMathTests: XCTestCase {

    private func canvas(
        _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 200, _ h: CGFloat = 200,
        id: UUID = UUID()
    ) -> CanvasModel {
        var model = CanvasModel(type: .gameOfLife, frame: CGRect(x: x, y: y, width: w, height: h))
        model = CanvasModel(
            id: id,
            type: model.type,
            frame: model.frame,
            gameOfLifeConfig: model.gameOfLifeConfig,
            videoConfig: model.videoConfig
        )
        return model
    }

    /// A stable UUID so two canvases can be told apart in a test.
    private func fixed(_ tag: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in tag.utf8.enumerated() {
            bytes[i % 16] = byte
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func testNoOverlapForSideBySideCanvases() {
        XCTAssertTrue(OverlapResolver.detectOverlaps(in: [canvas(0, 0), canvas(200, 0)]).isEmpty)
    }

    func testNoOverlapWhenTouchingExactly() {
        let a = canvas(0, 0, 200, 200)
        let b = canvas(200, 0, 200, 200)
        XCTAssertTrue(OverlapResolver.detectOverlaps(in: [a, b]).isEmpty,
                      "Edge contact is not a pixel overlap")
    }

    func testSinglePixelOverlapIsDetected() {
        let a = canvas(0, 0, 200, 200)
        let b = canvas(199.5, 0, 200, 200)
        XCTAssertEqual(OverlapResolver.detectOverlaps(in: [a, b]).count, 1)
    }

    func testContainmentCountsAsOverlap() {
        let outer = canvas(0, 0, 400, 400)
        let inner = canvas(100, 100, 50, 50)
        XCTAssertEqual(OverlapResolver.detectOverlaps(in: [outer, inner]).count, 1)
    }

    func testIdenticalFramesOverlap() {
        let a = canvas(10, 10, 100, 100)
        let b = canvas(10, 10, 100, 100)
        XCTAssertEqual(OverlapResolver.detectOverlaps(in: [a, b]).count, 1)
    }

    func testPairwiseOverlapsAreSymmetricAndUnique() {
        let a = canvas(0, 0, 200, 200)
        let b = canvas(100, 100, 200, 200)
        let c = canvas(150, 150, 200, 200)
        let pairs = OverlapResolver.detectOverlaps(in: [a, b, c])
        let keys = Set(pairs.map { Set([$0.0, $0.1]) })
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(keys.count, 3)
    }

    func testThreeFullyOverlappingCanvasesYieldThreePairs() {
        let canvases = [canvas(0, 0), canvas(0, 0), canvas(0, 0)]
        XCTAssertEqual(OverlapResolver.detectOverlaps(in: canvases).count, 3)
    }

    func testEmptyAndSingleInput() {
        XCTAssertTrue(OverlapResolver.detectOverlaps(in: []).isEmpty)
        XCTAssertTrue(OverlapResolver.detectOverlaps(in: [canvas(0, 0)]).isEmpty)
    }

    func testNonOverlappingLayoutPassesValidate() {
        XCTAssertNoThrow(try OverlapResolver.validate([
            canvas(0, 0), canvas(300, 0), canvas(0, 300), canvas(300, 300)
        ]))
    }

    func testValidateErrorNamesBothCanvases() {
        let a = canvas(0, 0)
        let b = canvas(50, 50)
        XCTAssertThrowsError(try OverlapResolver.validate([a, b])) { error in
            let localized = error.localizedDescription
            XCTAssertTrue(localized.contains(a.id.uuidString), "missing first id: \(localized)")
            XCTAssertTrue(localized.contains(b.id.uuidString), "missing second id: \(localized)")
        }
    }

    // MARK: - Resolve (push-apart)

    func testResolvePushesMovingCanvasClearOfOther() {
        let other = canvas(0, 0, 200, 200)
        let moving = canvas(100, 0, 200, 200)
        let resolved = OverlapResolver.resolve(moving: moving, against: [other])
        XCTAssertFalse(
            resolved.intersects(other.frame),
            "resolved frame \(resolved) must not intersect \(other.frame)"
        )
    }

    func testResolveIsANoOpWhenAlreadyClear() {
        let other = canvas(0, 0, 200, 200)
        let moving = canvas(400, 400, 200, 200)
        XCTAssertEqual(OverlapResolver.resolve(moving: moving, against: [other]), moving.frame)
    }

    func testResolvePreservesMovingCanvasSize() {
        let other = canvas(0, 0, 200, 200)
        let moving = canvas(150, 150, 320, 240)
        let resolved = OverlapResolver.resolve(moving: moving, against: [other])
        XCTAssertEqual(resolved.size, moving.frame.size)
    }

    func testResolveClearsMultipleOverlaps() {
        let others = [canvas(0, 0, 200, 200), canvas(200, 0, 200, 200), canvas(400, 0, 200, 200)]
        let moving = canvas(180, 50, 300, 200)
        let resolved = OverlapResolver.resolve(moving: moving, against: others)
        for other in others {
            XCTAssertFalse(resolved.intersects(other.frame), "still overlaps \(other.frame)")
        }
    }

    func testResolveRespectsPreferredDirection() {
        let other = canvas(0, 0, 200, 200)
        let moving = canvas(100, 100, 200, 200)

        let toTheRight = OverlapResolver.resolve(
            moving: moving, against: [other], preferredDirection: CGVector(dx: 1, dy: 0)
        )
        let toTheLeft = OverlapResolver.resolve(
            moving: moving, against: [other], preferredDirection: CGVector(dx: -1, dy: 0)
        )
        XCTAssertFalse(toTheRight.intersects(other.frame))
        XCTAssertFalse(toTheLeft.intersects(other.frame))
        XCTAssertNotEqual(toTheRight.origin.x, toTheLeft.origin.x)
    }

    func testResolveWithNoObstaclesIsIdentity() {
        let moving = canvas(10, 20, 100, 100)
        XCTAssertEqual(OverlapResolver.resolve(moving: moving, against: []), moving.frame)
    }

    // MARK: - Frame / screen mapping (H1 + H2)

    func testScreenMappingPlacesCanvasOnItsOwnScreen() {
        // Secondary display to the right of the primary one, AppKit coordinates.
        let screen = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let canvas = CGRect(x: 1600, y: 500, width: 400, height: 300)

        let local = ScreenGeometry.localFrame(for: canvas, in: screen)
        // The window sits at screen.frame, so the canvas offset is all that changes.
        XCTAssertEqual(local, CGRect(x: 160, y: 500, width: 400, height: 300))
    }

    func testScreenMappingIsIdentityForPrimaryOriginScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvas = CGRect(x: 300, y: 400, width: 500, height: 500)
        XCTAssertEqual(ScreenGeometry.localFrame(for: canvas, in: screen), canvas)
    }

    func testScreenMapperDoesNotMirrorVertically() {
        // Layout coordinates are the same bottom-left y-up space NSScreen uses, so
        // a canvas near the bottom of the display (the dock side) must land near
        // the bottom of its window. Mirroring here would render it at the menu
        // bar instead.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let local = ScreenGeometry.localFrame(for: canvas, in: screen)
        XCTAssertEqual(local.minY, 0)
        XCTAssertEqual(local.maxY, 300)
        XCTAssertNotEqual(local.minY, screen.height - canvas.height)
    }

    func testScreenMappingTranslatesANegativeOriginScreen() {
        // A display arranged left of and above the primary one.
        let screen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        let canvas = CGRect(x: -1200, y: 1000, width: 300, height: 200)
        XCTAssertEqual(
            ScreenGeometry.localFrame(for: canvas, in: screen),
            CGRect(x: 240, y: 100, width: 300, height: 200)
        )
    }

    func testScreenMappingRoundTrips() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let canvas = CGRect(x: -1200, y: 300, width: 300, height: 200)

        let local = ScreenGeometry.localFrame(for: canvas, in: screen)
        let back = ScreenGeometry.globalFrame(for: local, in: screen)
        XCTAssertEqual(back, canvas)
    }

    func testScreenMapperOnlyKeepsCanvasesOnThatScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let canvases = [canvas(100, 100, 200, 200), canvas(1500, 100, 200, 200)]

        let onLeft = ScreenGeometry.canvasesVisible(on: left, in: canvases).map(\.id)
        let onRight = ScreenGeometry.canvasesVisible(on: right, in: canvases).map(\.id)
        XCTAssertEqual(onLeft, [canvases[0].id])
        XCTAssertEqual(onRight, [canvases[1].id])
        XCTAssertTrue(Set(onLeft).isDisjoint(with: Set(onRight)))
    }

    func testScreenMapperDropsCanvasFullyOffEveryScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let faraway = canvas(9000, 9000, 100, 100)
        XCTAssertTrue(ScreenGeometry.canvasesVisible(on: left, in: [faraway]).isEmpty)
        XCTAssertTrue(ScreenGeometry.canvasesVisible(on: right, in: [faraway]).isEmpty)
    }

    func testScreenMapperCountsPartiallyVisibleCanvasOnce() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let straddling = canvas(1300, 100, 300, 200)
        XCTAssertEqual(ScreenGeometry.canvasesVisible(on: left, in: [straddling]).count, 1)
        XCTAssertEqual(ScreenGeometry.canvasesVisible(on: right, in: [straddling]).count, 1)
    }

    func testScreenMapperPreservesOrder() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let canvases = [canvas(0, 0, 100, 100), canvas(300, 0, 100, 100), canvas(600, 0, 100, 100)]
        let visible = ScreenGeometry.canvasesVisible(on: screen, in: canvases)
        XCTAssertEqual(visible.map(\.id), canvases.map(\.id))
    }

    func testFullMappingIsIdempotentForSingleScreenLayout() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvases = [canvas(100, 100, 400, 300), canvas(600, 700, 500, 250)]
        let visible = ScreenGeometry.canvasesVisible(on: screen, in: canvases)
        let local = visible.map { ScreenGeometry.localFrame(for: $0.frame, in: screen) }
        let back = local.map { ScreenGeometry.globalFrame(for: $0, in: screen) }
        XCTAssertEqual(back, canvases.map(\.frame))
    }

    // MARK: - Point mapping and the editor preview (H2)

    func testLocalPointMatchesTheLocalFrameOfItsOwnRect() {
        let screen = CGRect(x: 1440, y: 25, width: 1440, height: 900)
        let canvas = CGRect(x: 1600, y: 500, width: 400, height: 300)
        let local = ScreenGeometry.localFrame(for: canvas, in: screen)

        XCTAssertEqual(
            ScreenGeometry.localPoint(for: canvas.origin, in: screen),
            CGPoint(x: local.minX, y: local.minY)
        )
        XCTAssertEqual(
            ScreenGeometry.localPoint(for: CGPoint(x: canvas.maxX, y: canvas.maxY), in: screen),
            CGPoint(x: local.maxX, y: local.maxY)
        )
    }

    func testGlobalPointRoundTripsThroughLocalPoint() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let point = CGPoint(x: -1200, y: 100)
        XCTAssertEqual(
            ScreenGeometry.globalPoint(fromLocal: ScreenGeometry.localPoint(for: point, in: screen), in: screen),
            point
        )
    }

    func testPreviewKeepsTheLayoutsOrientation() {
        // The preview view (`LayoutNSView`) does NOT override `isFlipped`, so it
        // shares the stored layout's bottom-left, y-up convention. A canvas near
        // the bottom of the display must land near the bottom of the preview,
        // exactly as it renders on the desktop. Flipping only the preview made a
        // dock-side canvas appear at the top of the editor.
        let scale: CGFloat = 0.5
        let offset = CGPoint(x: 10, y: 20)

        let nearBottom = ScreenGeometry.previewRect(
            for: CGRect(x: 0, y: 60, width: 400, height: 300),
            scale: scale, offset: offset
        )
        let nearTop = ScreenGeometry.previewRect(
            for: CGRect(x: 0, y: 780, width: 400, height: 300),
            scale: scale, offset: offset
        )

        // Lower stored y == lower view y (do not flip).
        XCTAssertLessThan(nearBottom.minY, nearTop.minY)
        XCTAssertEqual(nearBottom.minY, 60 * scale + offset.y, accuracy: 0.0001)
        XCTAssertEqual(nearTop.minY, 780 * scale + offset.y, accuracy: 0.0001)
        XCTAssertEqual(nearBottom.minX, offset.x, accuracy: 0.0001)
    }

    func testPreviewRectRoundTripsThroughCanvasPoint() {
        let scale: CGFloat = 0.37
        let offset = CGPoint(x: -13, y: 71)
        let canvas = CGRect(x: -1500, y: 300, width: 640, height: 480)

        let preview = ScreenGeometry.previewRect(
            for: canvas, scale: scale, offset: offset
        )
        let corners = [preview.origin,
                       CGPoint(x: preview.maxX, y: preview.maxY)]
        let recovered = corners.map {
            ScreenGeometry.canvasPoint(
                fromViewPoint: $0, scale: scale, offset: offset
            )
        }
        XCTAssertEqual(recovered[0].x, canvas.minX, accuracy: 0.0001)
        XCTAssertEqual(recovered[0].y, canvas.minY, accuracy: 0.0001)
        XCTAssertEqual(recovered[1].x, canvas.maxX, accuracy: 0.0001)
        XCTAssertEqual(recovered[1].y, canvas.maxY, accuracy: 0.0001)
    }

    func testPreviewMappingAgreesWithTheWindowMapping() {
        // The whole point of routing both through ScreenGeometry: the canvas
        // drawn in the preview and the canvas shown on the desktop must describe
        // the same physical rectangle, up to the preview's scale. Both are y-up,
        // so their distances from the display's bottom edge agree directly.
        let union = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvas = CGRect(x: 220, y: 60, width: 800, height: 500)
        let scale: CGFloat = 0.25
        let offset = CGPoint(x: 40, y: 25)

        let preview = ScreenGeometry.previewRect(
            for: canvas, scale: scale, offset: offset
        )
        let windowFrame = ScreenGeometry.localFrame(for: canvas, in: union)

        XCTAssertEqual((preview.minY - offset.y) / scale, windowFrame.minY, accuracy: 0.0001)
        XCTAssertEqual((preview.maxY - offset.y) / scale, windowFrame.maxY, accuracy: 0.0001)
        XCTAssertEqual((preview.minX - offset.x) / scale, windowFrame.minX, accuracy: 0.0001)
        XCTAssertEqual(preview.width / scale, windowFrame.width, accuracy: 0.0001)
        XCTAssertEqual(preview.height / scale, windowFrame.height, accuracy: 0.0001)
    }

    func testPreviewMapsANegativeUnionOriginToTheCentredBox() {
        // A display left of / below the primary one gives the screen union a
        // negative origin, which the editor folds into `offset`. The mapping must
        // not subtract that origin a second time, or the whole arrangement is
        // pushed off the view.
        let union = CGRect(x: -1920, y: -200, width: 2880, height: 1080)
        let bounds = CGSize(width: 1200, height: 500)
        let pad: CGFloat = 40
        let scale = min(bounds.width / (union.width + 2 * pad),
                        bounds.height / (union.height + 2 * pad))
        let scaled = CGSize(width: union.width * scale, height: union.height * scale)
        let offset = CGPoint(
            x: (bounds.width - scaled.width) / 2 - union.minX * scale,
            y: (bounds.height - scaled.height) / 2 - union.minY * scale
        )

        let box = ScreenGeometry.previewRect(for: union, scale: scale, offset: offset)
        XCTAssertEqual(box.minX, (bounds.width - scaled.width) / 2, accuracy: 0.0001)
        XCTAssertEqual(box.minY, (bounds.height - scaled.height) / 2, accuracy: 0.0001)
        XCTAssertEqual(box.maxX, (bounds.width + scaled.width) / 2, accuracy: 0.0001)
        XCTAssertEqual(box.maxY, (bounds.height + scaled.height) / 2, accuracy: 0.0001)

        let centre = ScreenGeometry.previewRect(
            for: CGRect(x: union.midX, y: union.midY, width: 0, height: 0),
            scale: scale, offset: offset
        )
        XCTAssertEqual(centre.minX, bounds.width / 2, accuracy: 0.0001)
        XCTAssertEqual(centre.minY, bounds.height / 2, accuracy: 0.0001)
    }

    // MARK: - Drag-time resolution (design spec: "Canvas overlap prevention")

    func testResolveAcceptsAFrameThatIsNotYetInTheModel() {
        // The editor resolves a candidate frame on every mouse-moved, before it
        // has written the new frame back into the canvas list.
        let other = canvas(0, 0, 400, 400, id: fixed("OTHER"))
        let candidate = CGRect(x: 380, y: 0, width: 400, height: 400)

        let resolved = OverlapResolver.resolve(
            moving: candidate,
            excluding: fixed("DRAGGED"),
            against: [other]
        )
        XCTAssertFalse(resolved.intersects(other.frame))
        XCTAssertEqual(resolved.size, candidate.size)
    }

    func testResolveIgnoresTheCanvasItself() {
        // The dragged canvas keeps its stale frame in the model during the drag;
        // it must not be treated as its own obstacle.
        let dragged = canvas(0, 0, 400, 400, id: fixed("DRAGGED"))
        let candidate = CGRect(x: 0, y: 0, width: 400, height: 400)

        let resolved = OverlapResolver.resolve(
            moving: candidate,
            excluding: dragged.id,
            against: [dragged]
        )
        XCTAssertEqual(resolved, candidate)
    }

    func testResolveMatchesTheModelBasedEntryPoint() {
        let other = canvas(0, 0, 400, 400, id: fixed("OTHER"))
        let moving = canvas(380, 0, 400, 400, id: fixed("DRAGGED"))

        XCTAssertEqual(
            OverlapResolver.resolve(
                moving: moving,
                against: [other],
                preferredDirection: CGVector(dx: 1, dy: 0)
            ),
            OverlapResolver.resolve(
                moving: moving.frame,
                excluding: moving.id,
                against: [other],
                preferredDirection: CGVector(dx: 1, dy: 0)
            )
        )
    }

    func testDragPushDirectionFollowsTheDrag() {
        // Dragging right pushes the canvas further right rather than back left,
        // so the canvas follows the pointer instead of jumping away from it.
        let left = canvas(0, 0, 300, 300, id: fixed("LEFT"))
        let right = canvas(600, 0, 300, 300, id: fixed("RIGHT"))
        let candidate = CGRect(x: 280, y: 0, width: 300, height: 300)

        let resolved = OverlapResolver.resolve(
            moving: candidate,
            excluding: fixed("DRAGGED"),
            against: [left, right],
            preferredDirection: CGVector(dx: 1, dy: 0)
        )
        XCTAssertGreaterThanOrEqual(resolved.minX, left.frame.maxX)
    }
}