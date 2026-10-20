import Foundation
import CoreGraphics

/// Pure snapping geometry for the layout editor.
///
/// Lives in the `DesktopCanvas` library rather than the demo app so the snap
/// behaviour can be unit-tested: it depends only on CoreGraphics and
/// `CanvasModel`, never on SwiftUI or AppKit.
public struct SnapEngine {
    public var gridSize: CGFloat
    public var snapToScreenEdges: Bool
    public var snapToCanvasEdges: Bool
    public var snapToGrid: Bool
    public var screenFrame: CGRect
    public var otherCanvases: [(id: UUID, frame: CGRect)]
    public var margin: CGFloat
    public var snapThreshold: CGFloat

    /// Shared snap tolerance. The editor's guide overlay reads this so a guide
    /// appears exactly when the snap would fire.
    public static let defaultSnapThreshold: CGFloat = 6

    public init(
        gridSize: CGFloat,
        snapToScreenEdges: Bool,
        snapToCanvasEdges: Bool,
        snapToGrid: Bool,
        screenFrame: CGRect,
        otherCanvases: [(id: UUID, frame: CGRect)],
        margin: CGFloat,
        snapThreshold: CGFloat = SnapEngine.defaultSnapThreshold
    ) {
        self.gridSize = gridSize
        self.snapToScreenEdges = snapToScreenEdges
        self.snapToCanvasEdges = snapToCanvasEdges
        self.snapToGrid = snapToGrid
        self.screenFrame = screenFrame
        self.otherCanvases = otherCanvases
        self.margin = margin
        self.snapThreshold = snapThreshold
    }

    public func snapRect(_ rect: CGRect, excluding excludedID: UUID? = nil) -> CGRect {
        var result = rect
        result.origin = snapEdgePoint(rect, excluding: excludedID)
        return result
    }

    public func snapSize(_ size: CGSize, for canvas: CanvasModel) -> CGSize {
        if canvas.type == .gameOfLife {
            // `cellSize` is clamped to at least 2 by `GameOfLifeConfig`, but this
            // engine is also driven from live drags, so guard the division itself.
            let cellSize = CGFloat(canvas.gameOfLifeConfig?.cellSize ?? 8)
            guard cellSize > 0 else { return size }
            let snappedW = (size.width / cellSize).rounded() * cellSize
            let snappedH = (size.height / cellSize).rounded() * cellSize
            return CGSize(
                width: max(snappedW, 10 * cellSize),
                height: max(snappedH, 10 * cellSize)
            )
        }
        return size
    }

    public func snapResizeSize(_ size: CGSize, canvasID: UUID, canvas: CanvasModel) -> CGSize {
        var result = snapSize(size, for: canvas)

        if snapToCanvasEdges {
            for other in otherCanvases where other.id != canvasID {
                let ow = other.frame.width
                let oh = other.frame.height
                if abs(result.width - ow) < snapThreshold {
                    result.width = ow
                }
                if abs(result.height - oh) < snapThreshold {
                    result.height = oh
                }
            }
        }

        return result
    }

    private enum SnapAxis { case x, y }

    /// Snap targets, kept separate per axis.
    ///
    /// x and y values used to share one flat list, so a rect's left edge could
    /// snap to some other rect's *bottom* edge. On a 1920x1080 display that meant
    /// dragging a canvas towards y = 960 yanked it onto the screen's horizontal
    /// midline, which is an x coordinate.
    private struct AxisTargets {
        var x: [CGFloat] = []
        var y: [CGFloat] = []

        func values(for axis: SnapAxis) -> [CGFloat] {
            axis == .x ? x : y
        }
    }

    private func snapEdgePoint(_ rect: CGRect, excluding excludedID: UUID?) -> CGPoint {
        let targets = candidateSnapTargets(excluding: excludedID)

        var bestX = rect.origin.x
        var bestY = rect.origin.y
        var bestXDistance = snapThreshold
        var bestYDistance = snapThreshold

        for target in targets.x {
            let leftDist = abs(rect.minX - target)
            if leftDist < bestXDistance {
                bestX = target
                bestXDistance = leftDist
            }
            let rightDist = abs(rect.maxX - target)
            if rightDist < bestXDistance {
                bestX = target - rect.width
                bestXDistance = rightDist
            }
        }

        for target in targets.y {
            let bottomDist = abs(rect.minY - target)
            if bottomDist < bestYDistance {
                bestY = target
                bestYDistance = bottomDist
            }
            let topDist = abs(rect.maxY - target)
            if topDist < bestYDistance {
                bestY = target - rect.height
                bestYDistance = topDist
            }
        }

        return CGPoint(x: bestX, y: bestY)
    }

    /// The nearest snap target to a single moving edge, or `value` unchanged when
    /// nothing is within `snapThreshold`.
    ///
    /// Unlike `snapEdgePoint`, this resolves one coordinate: during a resize the
    /// user is steering a specific edge, so only that edge should snap.
    private func snappedCoordinate(
        _ value: CGFloat,
        axis: SnapAxis,
        excluding excludedID: UUID?,
        includeGrid: Bool = true
    ) -> CGFloat {
        var best = value
        var bestDistance = snapThreshold
        for target in candidateSnapTargets(excluding: excludedID, includeGrid: includeGrid).values(for: axis) {
            let distance = abs(value - target)
            if distance < bestDistance {
                best = target
                bestDistance = distance
            }
        }
        return best
    }

    private func candidateSnapTargets(
        excluding excludedID: UUID?,
        includeGrid: Bool = true
    ) -> AxisTargets {
        var targets = AxisTargets()

        if snapToScreenEdges {
            targets.x.append(screenFrame.minX)
            targets.x.append(screenFrame.maxX)
            targets.x.append(screenFrame.midX)
            targets.y.append(screenFrame.minY)
            targets.y.append(screenFrame.maxY)
            targets.y.append(screenFrame.midY)
        }

        if snapToCanvasEdges {
            for other in otherCanvases where other.id != excludedID {
                let f = other.frame
                // Edge-to-edge alignment, plus the configured gap. `margin` used
                // to be stored and never read, while the guide overlay did honour
                // it — so the editor promised a snap the engine never made.
                targets.x.append(f.minX)
                targets.x.append(f.maxX)
                targets.x.append(f.maxX + margin)
                targets.x.append(f.minX - margin)
                targets.y.append(f.minY)
                targets.y.append(f.maxY)
                targets.y.append(f.maxY + margin)
                targets.y.append(f.minY - margin)
            }
        }

        if snapToGrid, includeGrid {
            targets.x.append(contentsOf: gridTargets(from: screenFrame.minX, to: screenFrame.maxX))
            targets.y.append(contentsOf: gridTargets(from: screenFrame.minY, to: screenFrame.maxY))
        }

        return targets
    }

    /// Cell-multiple grid lines spanning the snapping area, for one axis.
    ///
    /// The drag is resolved against these exactly like every other snap target,
    /// so the grid toggle snaps edges and corners rather than origins only.
    private func gridTargets(from lower: CGFloat, to upper: CGFloat) -> [CGFloat] {
        guard gridSize > 0, gridSize.isFinite else { return [] }
        guard !screenFrame.isNull, !screenFrame.isEmpty else { return [] }

        var targets: [CGFloat] = []
        var value = (lower / gridSize).rounded(.down) * gridSize
        while value <= upper {
            targets.append(value)
            value += gridSize
        }
        return targets
    }

    /// Resizes `rect` by dragging `handle` to `target`.
    ///
    /// Every handle is honoured: corners resize both axes, edges resize one, and
    /// each anchors the opposite edge/corner so the anchor never drifts. Aspect-
    /// locked video canvases snap their horizontal edge exactly like Game of Life
    /// canvases do.
    public func snapCornerResize(
        rect: CGRect,
        handle: ResizeHandle,
        target: CGPoint,
        canvas: CanvasModel
    ) -> CGRect {
        var result = rect
        var edgeSnappedX = false
        var edgeSnappedY = false

        if canvas.type == .video, let naturalSize = canvas.videoConfig?.naturalSize,
           naturalSize.width > 0, naturalSize.height > 0 {
            result = aspectSnapCornerResize(
                rect: rect,
                handle: handle,
                target: target,
                aspectRatio: naturalSize.width / naturalSize.height,
                excluding: canvas.id
            )
        } else {
            let cellSize: CGFloat = canvas.type == .gameOfLife
                ? CGFloat(canvas.gameOfLifeConfig?.cellSize ?? 8)
                : 1
            let minExtent = 10 * cellSize

            // Screen and canvas edges steer the edge under the cursor — and, when
            // neither is near, the grid does. This path used to grid-round only,
            // so resizing a canvas could never land flush on a screen edge.
            let snappedTarget = CGPoint(
                x: snappedCoordinate(target.x, axis: .x, excluding: canvas.id),
                y: snappedCoordinate(target.y, axis: .y, excluding: canvas.id)
            )
            edgeSnappedX = snappedTarget.x != target.x
            edgeSnappedY = snappedTarget.y != target.y

            switch handle {
            case .topLeft:
                let newMinX = min(snappedTarget.x, result.maxX - minExtent)
                let newMinY = min(snappedTarget.y, result.maxY - minExtent)
                result = CGRect(
                    x: newMinX, y: newMinY,
                    width: result.maxX - newMinX, height: result.maxY - newMinY
                )
            case .topRight:
                let newMaxX = max(snappedTarget.x, result.minX + minExtent)
                let newMinY = min(snappedTarget.y, result.maxY - minExtent)
                result = CGRect(
                    x: result.minX, y: newMinY,
                    width: newMaxX - result.minX, height: result.maxY - newMinY
                )
            case .bottomLeft:
                let newMinX = min(snappedTarget.x, result.maxX - minExtent)
                let newMaxY = max(snappedTarget.y, result.minY + minExtent)
                result = CGRect(
                    x: newMinX, y: result.minY,
                    width: result.maxX - newMinX, height: newMaxY - result.minY
                )
            case .bottomRight:
                let newMaxX = max(snappedTarget.x, result.minX + minExtent)
                let newMaxY = max(snappedTarget.y, result.minY + minExtent)
                result = CGRect(
                    x: result.minX, y: result.minY,
                    width: newMaxX - result.minX, height: newMaxY - result.minY
                )
            case .top:
                let newMinY = min(snappedTarget.y, result.maxY - minExtent)
                result = CGRect(
                    x: result.minX, y: newMinY,
                    width: result.width, height: result.maxY - newMinY
                )
            case .bottom:
                let newMaxY = max(snappedTarget.y, result.minY + minExtent)
                result = CGRect(
                    x: result.minX, y: result.minY,
                    width: result.width, height: newMaxY - result.minY
                )
            case .left:
                let newMinX = min(snappedTarget.x, result.maxX - minExtent)
                result = CGRect(
                    x: newMinX, y: result.minY,
                    width: result.maxX - newMinX, height: result.height
                )
            case .right:
                let newMaxX = max(snappedTarget.x, result.minX + minExtent)
                result = CGRect(
                    x: result.minX, y: result.minY,
                    width: newMaxX - result.minX, height: result.height
                )
            }
        }

        if canvas.type == .gameOfLife {
            // Snap the size relative to the anchored edge/corner, applying the
            // snapped size only to the axes this handle controls so the anchor
            // cannot be dragged along with it.
            var newSize = snapResizeSize(result.size, canvasID: canvas.id, canvas: canvas)
            // An edge that was explicitly snapped to a screen or canvas target
            // keeps that alignment; rounding it back to whole cells would undo
            // the snap by up to half a cell.
            if edgeSnappedX { newSize.width = result.width }
            if edgeSnappedY { newSize.height = result.height }
            switch handle {
            case .topLeft:
                result = CGRect(x: result.maxX - newSize.width, y: result.maxY - newSize.height,
                                width: newSize.width, height: newSize.height)
            case .topRight:
                result = CGRect(x: result.minX, y: result.maxY - newSize.height,
                                width: newSize.width, height: newSize.height)
            case .bottomLeft:
                result = CGRect(x: result.maxX - newSize.width, y: result.minY,
                                width: newSize.width, height: newSize.height)
            case .bottomRight:
                result = CGRect(x: result.minX, y: result.minY,
                                width: newSize.width, height: newSize.height)
            case .top:
                result = CGRect(x: result.minX, y: result.maxY - newSize.height,
                                width: result.width, height: newSize.height)
            case .bottom:
                result = CGRect(x: result.minX, y: result.minY,
                                width: result.width, height: newSize.height)
            case .left:
                result = CGRect(x: result.maxX - newSize.width, y: result.minY,
                                width: newSize.width, height: result.height)
            case .right:
                result = CGRect(x: result.minX, y: result.minY,
                                width: newSize.width, height: result.height)
            }
        }

        return result
    }

    /// Aspect-locked resize: the horizontal edge under the cursor drives the
    /// width and the height follows from `aspectRatio`.
    private func aspectSnapCornerResize(
        rect: CGRect,
        handle: ResizeHandle,
        target: CGPoint,
        aspectRatio: CGFloat,
        excluding excludedID: UUID?
    ) -> CGRect {
        let minSize: CGFloat = 50
        // The edge being dragged is the one that snaps. Previously this path
        // ignored every snap target, so a video canvas resized with no snapping
        // at all; the vertical handles then only ever snapped their width.
        let x = snappedCoordinate(target.x, axis: .x, excluding: excludedID)
        let y = snappedCoordinate(target.y, axis: .y, excluding: excludedID)

        switch handle {
        case .bottomRight, .right:
            let newW = max(x - rect.minX, minSize)
            let newH = newW / aspectRatio
            return CGRect(x: rect.minX, y: rect.minY, width: newW, height: newH)

        case .bottomLeft:
            let newW = max(rect.maxX - x, minSize)
            let newH = newW / aspectRatio
            return CGRect(x: rect.maxX - newW, y: rect.minY, width: newW, height: newH)

        case .topRight:
            let newW = max(x - rect.minX, minSize)
            let newH = newW / aspectRatio
            return CGRect(x: rect.minX, y: rect.maxY - newH, width: newW, height: newH)

        case .topLeft:
            let newW = max(rect.maxX - x, minSize)
            let newH = newW / aspectRatio
            return CGRect(x: rect.maxX - newW, y: rect.maxY - newH, width: newW, height: newH)

        case .left:
            let newW = max(rect.maxX - x, minSize)
            let newH = newW / aspectRatio
            return CGRect(x: rect.maxX - newW, y: rect.minY, width: newW, height: newH)

        case .top:
            // A vertical drag steers the top edge, so that edge snaps and the
            // aspect ratio derives the width from it.
            let newH = max(rect.maxY - y, minSize)
            let newW = newH * aspectRatio
            return CGRect(x: rect.minX, y: rect.maxY - newH, width: newW, height: newH)

        case .bottom:
            let newH = max(y - rect.minY, minSize)
            let newW = newH * aspectRatio
            return CGRect(x: rect.minX, y: rect.minY, width: newW, height: newH)
        }
    }
}

public enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    public static let corners: [ResizeHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    public static let edges: [ResizeHandle] = [.top, .left, .right, .bottom]
}

extension ResizeHandle {
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}
