import SwiftUI
import DesktopCanvas

struct VisualLayoutView: NSViewRepresentable {
    @ObservedObject var state: EditorState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> LayoutNSView {
        let view = LayoutNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: LayoutNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.needsDisplay = true
    }

    final class Coordinator {
        let state: EditorState
        var dragHandle: ResizeHandle?
        var dragStartOrigin: CGPoint = .zero
        var dragStartSize: CGSize = .zero
        /// Canvas the most recent collision flash was drawn for, and when.
        private(set) var flashCanvasID: UUID?
        private(set) var flashExpiresAt: Date?

        init(state: EditorState) {
            self.state = state
        }

        private static let flashDuration: TimeInterval = 0.35

        /// Pushes `rect` clear of every other canvas and reports whether a
        /// collision had to be prevented.
        ///
        /// The design spec requires that no two canvases share any pixels, and
        /// that a collision is both snapped clear and flashed. `OverlapResolver`
        /// already computes both the detection and the push; this wires it into
        /// the drag path. Callers that hold a modifier pass
        /// `preferredDirection` = drag direction, which resolves a collision by
        /// continuing the drag rather than pushing sideways.
        @discardableResult
        func resolveOverlaps(
            rect: CGRect,
            excluding canvasID: UUID,
            preferredDirection: CGVector = .zero
        ) -> CGRect {
            let others = state.canvases.filter { $0.id != canvasID }
            guard !others.isEmpty else { return rect }

            let collides = others.contains { $0.frame.intersects(rect) }
            let resolved = OverlapResolver.resolve(
                moving: rect,
                excluding: canvasID,
                against: others,
                preferredDirection: preferredDirection
            )
            if collides {
                flash(canvasID)
            }
            return resolved
        }

        private func flash(_ canvasID: UUID) {
            flashCanvasID = canvasID
            flashExpiresAt = Date().addingTimeInterval(Self.flashDuration)
        }

        /// True while a collision flash is showing for `canvas`.
        func isFlashing(_ canvasID: UUID, now: Date = Date()) -> Bool {
            flashCanvasID == canvasID && now < (flashExpiresAt ?? .distantPast)
        }

        func snapEngine(for screen: NSScreen?, excluding id: UUID?) -> SnapEngine {
            let others = state.canvases
                .filter { $0.id != id }
                .map { (id: $0.id, frame: $0.frame) }
            return SnapEngine(
                gridSize: state.layoutGridSize,
                snapToScreenEdges: state.snapToScreenEdges,
                snapToCanvasEdges: state.snapToCanvasEdges,
                snapToGrid: state.snapEnabled,
                screenFrame: screen?.frame ?? .null,
                otherCanvases: others,
                margin: state.margin
            )
        }

        func commit() {
            guard state.isApplied else { return }
            // `refresh` re-frames the existing windows in place. `apply` would
            // tear every window down and rebuild it, which restarts video
            // playback, drops the running simulations, and is a known crash
            // risk when it happens inside an AppKit drag dispatch.
            state.refreshDesktop()
        }
    }
}

final class LayoutNSView: NSView {
    var coordinator: VisualLayoutView.Coordinator?
    private var trackingArea: NSTrackingArea?
    private var eventMonitor: Any?
    private var isDragging = false
    private var dragHandle: ResizeHandle?
    private var dragStartPoint: CGPoint = .zero
    private var dragCanvasID: UUID?
    private var cachedScreens: [NSScreen] = []
    private var cachedUnionFrame: CGRect = .zero
    private var cachedScale: CGFloat = 1
    private var cachedOffset: CGPoint = .zero
    private var snapGuides: [(axis: Character, position: CGFloat)] = []

    private static let handleSize: CGFloat = 7
    private static let handleHitPadding: CGFloat = 6

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator = coordinator else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenPoint = viewToScreen(viewPoint)

        if let (canvas, handle) = hitTestResizeHandle(screenPoint: screenPoint, coordinator: coordinator) {
            isDragging = true
            dragCanvasID = canvas.id
            dragHandle = handle
            dragStartPoint = screenPoint
            coordinator.dragHandle = handle
            coordinator.dragStartOrigin = canvas.frame.origin
            coordinator.dragStartSize = canvas.frame.size
            NSCursor.crosshair.set()
        } else if let canvas = hitTestCanvas(screenPoint: screenPoint, coordinator: coordinator) {
            isDragging = true
            dragCanvasID = canvas.id
            dragHandle = nil
            dragStartPoint = screenPoint
            coordinator.dragHandle = nil
            coordinator.dragStartOrigin = canvas.frame.origin
            coordinator.dragStartSize = canvas.frame.size
            coordinator.state.selectedCanvasID = canvas.id
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let coordinator = coordinator,
              let canvasID = dragCanvasID,
              let index = coordinator.state.canvases.firstIndex(where: { $0.id == canvasID })
        else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenPoint = viewToScreen(viewPoint)
        let delta = CGPoint(x: screenPoint.x - dragStartPoint.x, y: screenPoint.y - dragStartPoint.y)
        let canvas = coordinator.state.canvases[index]
        let screen = screenForCanvas(canvas) ?? NSScreen.main ?? cachedScreens.first
        let engine = coordinator.snapEngine(for: screen, excluding: canvas.id)
        let commandHeld = event.modifierFlags.contains(.command)

        if let handle = dragHandle {
            let newRect: CGRect
            if commandHeld {
                newRect = freeCornerResize(
                    rect: CGRect(origin: coordinator.dragStartOrigin, size: coordinator.dragStartSize),
                    handle: handle,
                    target: screenPoint,
                    canvas: canvas
                )
            } else {
                newRect = engine.snapCornerResize(
                    rect: CGRect(origin: coordinator.dragStartOrigin, size: coordinator.dragStartSize),
                    handle: handle,
                    target: screenPoint,
                    canvas: canvas
                )
            }
            coordinator.state.canvases[index].frame = commandHeld
                ? newRect
                : coordinator.resolveOverlaps(rect: newRect, excluding: canvas.id)
            if !commandHeld { buildSnapGuides(newRect) } else { snapGuides = [] }
        } else {
            let newOrigin = CGPoint(
                x: coordinator.dragStartOrigin.x + delta.x,
                y: coordinator.dragStartOrigin.y + delta.y
            )
            if commandHeld {
                coordinator.state.canvases[index].frame.origin = newOrigin
                snapGuides = []
            } else {
                let newRect = CGRect(origin: newOrigin, size: canvas.frame.size)
                let snappedRect = engine.snapRect(newRect, excluding: canvas.id)
                coordinator.state.canvases[index].frame.origin = snappedRect.origin
                buildSnapGuides(snappedRect)
            }
            if !commandHeld {
                coordinator.state.canvases[index].frame = coordinator.resolveOverlaps(
                    rect: coordinator.state.canvases[index].frame,
                    excluding: canvas.id,
                    preferredDirection: CGVector(dx: delta.x, dy: delta.y)
                )
            }
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        dragCanvasID = nil
        dragHandle = nil
        snapGuides = []
        coordinator?.dragHandle = nil
        coordinator?.commit()
        NSCursor.arrow.set()
        // Clears the collision flash once its duration has elapsed, since no
        // further mouse event is guaranteed to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let coordinator = coordinator else { return }
        let screenPoint = viewToScreen(convert(event.locationInWindow, from: nil))

        if hitTestResizeHandle(screenPoint: screenPoint, coordinator: coordinator) != nil {
            NSCursor.crosshair.set()
        } else if hitTestCanvas(screenPoint: screenPoint, coordinator: coordinator) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator = coordinator else { return }

        let bgColor: NSColor = .controlBackgroundColor
        bgColor.setFill()
        bounds.fill()

        cachedScreens = NSScreen.screens
        guard let primaryScreen = cachedScreens.first else { return }

        var unionRect = primaryScreen.frame
        for screen in cachedScreens {
            unionRect = unionRect.union(screen.frame)
        }
        cachedUnionFrame = unionRect

        let pad: CGFloat = 40
        let paddedUnion = unionRect.insetBy(dx: -pad, dy: -pad)
        let scaleX = bounds.width / paddedUnion.width
        let scaleY = bounds.height / paddedUnion.height
        cachedScale = min(scaleX, scaleY)

        let scaledWidth = unionRect.width * cachedScale
        let scaledHeight = unionRect.height * cachedScale
        cachedOffset = CGPoint(
            x: (bounds.width - scaledWidth) / 2 - unionRect.minX * cachedScale,
            y: (bounds.height - scaledHeight) / 2 - unionRect.minY * cachedScale
        )

        for screen in cachedScreens {
            drawScreen(screen, scale: cachedScale, offset: cachedOffset)
        }

        for canvas in coordinator.state.canvases {
            let isSelected = canvas.id == coordinator.state.selectedCanvasID
            drawCanvas(canvas, isSelected: isSelected, scale: cachedScale, offset: cachedOffset, coordinator: coordinator)
        }

        for guide in snapGuides {
            drawSnapGuide(guide, scale: cachedScale, offset: cachedOffset)
        }
    }

    private func drawScreen(_ screen: NSScreen, scale: CGFloat, offset: CGPoint) {
        let rect = scaledRect(screen.frame, scale: scale, offset: offset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)

        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        path.fill()

        NSColor.quaternaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let label = screen.localizedName
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let labelPoint = CGPoint(
            x: rect.minX + 6,
            y: rect.maxY - size.height - 4
        )
        (label as NSString).draw(at: labelPoint, withAttributes: attrs)
    }

    private func drawCanvas(
        _ canvas: CanvasModel,
        isSelected: Bool,
        scale: CGFloat,
        offset: CGPoint,
        coordinator: VisualLayoutView.Coordinator?
    ) {
        let rect = scaledRect(canvas.frame, scale: scale, offset: offset)

        let fillColor: NSColor = switch canvas.type {
        case .gameOfLife: NSColor.systemGreen.withAlphaComponent(0.25)
        case .video: NSColor.systemBlue.withAlphaComponent(0.25)
        }

        let defaultStrokeColor: NSColor = switch canvas.type {
        case .gameOfLife: NSColor.systemGreen.withAlphaComponent(0.6)
        case .video: NSColor.systemBlue.withAlphaComponent(0.6)
        }
        let strokeColor: NSColor = isSelected
            ? NSColor.controlAccentColor
            : defaultStrokeColor

        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        fillColor.setFill()
        path.fill()

        strokeColor.setStroke()
        path.lineWidth = isSelected ? 2 : 1
        path.stroke()

        let name = switch canvas.type {
        case .gameOfLife: "Game of Life"
        case .video: "Video"
        }
        let sizeStr = "\(Int(canvas.frame.width))×\(Int(canvas.frame.height))"
        let label = rect.width > 60 ? "\(name)\n\(sizeStr)" : (rect.width > 30 ? name : "")

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.labelColor
        ]
        let labelSize = (label as NSString).size(withAttributes: attrs)
        let labelPoint = CGPoint(
            x: rect.midX - labelSize.width / 2,
            y: rect.midY - labelSize.height / 2
        )
        (label as NSString).draw(at: labelPoint, withAttributes: attrs)

        if isSelected {
            for handle in ResizeHandle.corners {
                let hp = handlePoint(handle, in: rect)
                let hRect = CGRect(
                    x: hp.x - Self.handleSize / 2,
                    y: hp.y - Self.handleSize / 2,
                    width: Self.handleSize,
                    height: Self.handleSize
                )
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: hRect).fill()
            }
        }

        // Red flash border for the 0.35s after a collision was snapped clear,
        // as the design spec requires.
        if coordinator?.isFlashing(canvas.id) == true {
            let flashPath = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor.systemRed.setStroke()
            flashPath.lineWidth = 3
            flashPath.stroke()
        }
    }

    private func scaledRect(_ rect: CGRect, scale: CGFloat, offset: CGPoint) -> CGRect {
        ScreenGeometry.previewRect(
            for: rect,
            scale: scale,
            offset: offset
        )
    }

    private func viewToScreen(_ viewPoint: CGPoint) -> CGPoint {
        ScreenGeometry.canvasPoint(
            fromViewPoint: viewPoint,
            scale: cachedScale,
            offset: cachedOffset
        )
    }

    private func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
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

    private func hitTestResizeHandle(
        screenPoint: CGPoint,
        coordinator: VisualLayoutView.Coordinator
    ) -> (CanvasModel, ResizeHandle)? {
        guard let selected = coordinator.state.selectedCanvas else { return nil }
        let handleRadius = (Self.handleSize / 2 + Self.handleHitPadding) / cachedScale

        for handle in ResizeHandle.corners {
            let hp = handle.point(in: selected.frame)
            let dx = screenPoint.x - hp.x
            let dy = screenPoint.y - hp.y
            if sqrt(dx * dx + dy * dy) <= handleRadius {
                return (selected, handle)
            }
        }

        return nil
    }

    private func hitTestCanvas(
        screenPoint: CGPoint,
        coordinator: VisualLayoutView.Coordinator
    ) -> CanvasModel? {
        for canvas in coordinator.state.canvases.reversed() {
            if canvas.frame.contains(screenPoint) {
                return canvas
            }
        }
        return nil
    }

    private func screenForCanvas(_ canvas: CanvasModel) -> NSScreen? {
        cachedScreens.first { $0.frame.intersects(canvas.frame) }
    }

    /// Command-drag resize: no snapping and no cell multiples, but the result is
    /// still held to the same 32pt minimum every other entry point enforces, and
    /// the anchored corner never moves.
    private func freeCornerResize(rect: CGRect, handle: ResizeHandle, target: CGPoint, canvas: CanvasModel) -> CGRect {
        let minSize: CGFloat = 32

        let ratio: CGFloat?
        if canvas.type == .video, let size = canvas.videoConfig?.naturalSize,
           size.width > 0, size.height > 0 {
            ratio = size.width / size.height
        } else {
            ratio = nil
        }

        // Signed extent from the anchored edge to the dragged point, then clamped
        // so a drag past the anchor can never produce a negative size.
        func clamped(_ width: CGFloat, _ height: CGFloat) -> CGSize {
            let clampedW = max(width.isFinite ? width : minSize, minSize)
            let clampedH = ratio != nil
                ? clampedW / ratio!
                : max(height.isFinite ? height : minSize, minSize)
            return CGSize(width: clampedW, height: clampedH)
        }

        switch handle {
        case .bottomRight:
            let size = clamped(target.x - rect.minX, target.y - rect.minY)
            return CGRect(x: rect.minX, y: rect.minY, width: size.width, height: size.height)
        case .bottomLeft:
            let size = clamped(rect.maxX - target.x, target.y - rect.minY)
            return CGRect(x: rect.maxX - size.width, y: rect.minY,
                          width: size.width, height: size.height)
        case .topRight:
            let size = clamped(target.x - rect.minX, rect.maxY - target.y)
            return CGRect(x: rect.minX, y: rect.maxY - size.height,
                          width: size.width, height: size.height)
        case .topLeft:
            let size = clamped(rect.maxX - target.x, rect.maxY - target.y)
            return CGRect(x: rect.maxX - size.width, y: rect.maxY - size.height,
                          width: size.width, height: size.height)
        case .top, .bottom, .left, .right:
            return rect
        }
    }

    private func buildSnapGuides(_ rect: CGRect) {
        var guides: [(Character, CGFloat)] = []

        guard let coordinator = coordinator else {
            snapGuides = guides
            return
        }

        // A guide is only worth drawing when it is one of the targets the snap engine
        // actually resolved against, so the tolerance matches `SnapEngine`'s.
        let threshold = SnapEngine.defaultSnapThreshold

        guard let screen = screenForCanvas(
            CanvasModel(type: .gameOfLife, frame: rect)
        ) ?? cachedScreens.first else {
            snapGuides = guides
            return
        }

        let others = coordinator.state.canvases.filter { $0.id != dragCanvasID }

        if coordinator.state.snapToScreenEdges {
            let sf = screen.frame
            if abs(rect.minX - sf.minX) < threshold { guides.append(("x", sf.minX)) }
            if abs(rect.maxX - sf.maxX) < threshold { guides.append(("x", sf.maxX)) }
            if abs(rect.minY - sf.minY) < threshold { guides.append(("y", sf.minY)) }
            if abs(rect.maxY - sf.maxY) < threshold { guides.append(("y", sf.maxY)) }
            if abs(rect.minX - sf.midX) < threshold || abs(rect.maxX - sf.midX) < threshold {
                guides.append(("x", sf.midX))
            }
            if abs(rect.minY - sf.midY) < threshold || abs(rect.maxY - sf.midY) < threshold {
                guides.append(("y", sf.midY))
            }
        }

        if coordinator.state.snapToCanvasEdges {
            for other in others {
                let f = other.frame
                let margin = coordinator.state.margin
                if abs(rect.minX - f.maxX - margin) < threshold { guides.append(("x", f.maxX + margin)) }
                if abs(rect.maxX - f.minX + margin) < threshold { guides.append(("x", f.minX - margin)) }
                if abs(rect.minX - f.minX) < threshold { guides.append(("x", f.minX)) }
                if abs(rect.maxX - f.maxX) < threshold { guides.append(("x", f.maxX)) }
                if abs(rect.minY - f.maxY - margin) < threshold { guides.append(("y", f.maxY + margin)) }
                if abs(rect.maxY - f.minY + margin) < threshold { guides.append(("y", f.minY - margin)) }
                if abs(rect.minY - f.minY) < threshold { guides.append(("y", f.minY)) }
                if abs(rect.maxY - f.maxY) < threshold { guides.append(("y", f.maxY)) }
            }
        }

        snapGuides = guides
    }

    private func drawSnapGuide(_ guide: (axis: Character, position: CGFloat), scale: CGFloat, offset: CGPoint) {
        let scaledPos = guide.position * scale + (guide.axis == "x" ? offset.x : offset.y)
        let pattern: [CGFloat] = [4, 4]
        let path = NSBezierPath()

        if guide.axis == "x" {
            path.move(to: CGPoint(x: scaledPos, y: bounds.minY))
            path.line(to: CGPoint(x: scaledPos, y: bounds.maxY))
        } else {
            path.move(to: CGPoint(x: bounds.minX, y: scaledPos))
            path.line(to: CGPoint(x: bounds.maxX, y: scaledPos))
        }

        path.setLineDash(pattern, count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.systemYellow.setStroke()
        path.stroke()
    }
}