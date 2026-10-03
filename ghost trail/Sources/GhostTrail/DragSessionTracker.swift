import Foundation
import CoreGraphics
import AppKit

/// What a mouse-down on a particular window turned out to be.
enum WindowInteraction: Equatable {
    /// The point is in the window's title bar band — dragging moves the window.
    case drag
    /// The point is within the resize border or a corner of the window —
    /// dragging changes its size. Recorded explicitly because a resize leaves
    /// the origin untouched, so it cannot be inferred from motion alone.
    case resize
    /// The point is inside the window but in neither band: a click into the
    /// content, which moves nothing.
    case body
}

/// Pure hit-testing for a mouse-down, kept separate from the event tap so it can
/// be exercised without a live window server.
enum WindowInteractionTester {
    /// Height of the title-bar drag band measured down from the window's top.
    /// 28pt comfortably covers the traffic lights plus title bar on every
    /// default macOS window, including the compact header of a document window.
    static let titleBarHeight: CGFloat = 28
    /// How close to an edge counts as a resize grip.
    static let resizeBorder: CGFloat = 6

    /// - Parameters:
    ///   - point: mouse location in Quartz-global coordinates (top-left origin,
    ///     `+y` down) — the same space `CGWindowListCopyWindowInfo` reports.
    ///   - frame: the window's bounds in that same space.
    static func interaction(at point: CGPoint, in frame: CGRect) -> WindowInteraction? {
        guard frame.contains(point) else { return nil }

        let distanceFromLeft = point.x - frame.minX
        let distanceFromRight = frame.maxX - point.x
        let distanceFromTop = point.y - frame.minY
        let distanceFromBottom = frame.maxY - point.y

        let nearHorizontalEdge = min(distanceFromLeft, distanceFromRight) <= resizeBorder
        let nearVerticalEdge = min(distanceFromTop, distanceFromBottom) <= resizeBorder

        // Corners win over the body, and edges win over the title bar: a mouse
        // down in the top-left 6pt of a window resizes, even though that point
        // is also inside the title bar band.
        if (nearHorizontalEdge && nearVerticalEdge) || nearHorizontalEdge || nearVerticalEdge {
            return .resize
        }

        if distanceFromTop <= titleBarHeight {
            return .drag
        }

        return .body
    }

    /// Whether two ordered window frames overlap enough that the smaller is
    /// fully or mostly hidden by the larger. macOS always delivers the frontmost
    /// window first, so the first match wins.
    static func frontmostWindow(at point: CGPoint, in orderedFrames: [CGRect]) -> Int? {
        for (index, frame) in orderedFrames.enumerated() where frame.contains(point) {
            return index
        }
        return nil
    }
}

/// Maintains the set of windows the user is currently manipulating, driven by a
/// read-only `CGEventTap` on the mouse buttons.
///
/// Geometry alone cannot tell a drag from an animation. A window that opens,
/// restores from the Dock, or is moved by a script all change frame without
/// anyone touching it; the old tracker trailed all of them. Watching the mouse
/// button answers the question directly: a window is eligible exactly while the
/// pointer is down on its title bar or its resize border.
///
/// If the event tap cannot be installed — which on macOS requires Accessibility
/// permission — the tracker reports `false` from `start()` and the caller falls
/// back to geometry-only eligibility. That degradation is deliberate: a missing
/// permission must soften the trails, not remove them.
final class DragSessionTracker {
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Window currently being dragged or resized.
    private var activeWindowID: CGWindowID?
    private var activeInteraction: WindowInteraction?
    /// Where the mouse went down, in Quartz-global coordinates.
    private var pressLocation: CGPoint = .zero
    /// How far the pointer may travel before a press counts as a gesture.
    private let dragActivationDistance: CGFloat
    private var pressIsGesture = false
    private var mouseIsDown = false

    /// Last known on-screen frames, frontmost first, keyed by window ID.
    private var orderedFrames: [(id: CGWindowID, frame: CGRect)] = []

    private(set) var lastError: String?

    init(dragActivationDistance: CGFloat = 2) {
        self.dragActivationDistance = max(dragActivationDistance, 0)
    }

    deinit {
        stop()
    }

    /// Windows that should currently be drawing a trail: the one under the
    /// pointer while the button is down.
    var eligibleWindows: Set<CGWindowID> {
        guard pressIsGesture, mouseIsDown, let id = activeWindowID else { return [] }
        return [id]
    }

    /// Refreshes the front-to-back window ordering used for hit testing. Must be
    /// called before `handleMouseDown`, once per poll.
    func updateWindowOrder(_ frames: [CGWindowID: CGRect]) {
        orderedFrames = frames
            .sorted { lhs, rhs in
                // Frontmost first: larger windows are typically behind, and for
                // equal-size windows CGWindowListCopyWindowInfo's front-to-back
                // order is lost when it is flattened into a dictionary, so fall
                // back to a stable id tiebreak.
                if lhs.value.width * lhs.value.height != rhs.value.width * rhs.value.height {
                    return lhs.value.width * lhs.value.height < rhs.value.width * rhs.value.height
                }
                return lhs.key < rhs.key
            }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Event tap

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<DragSessionTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handleMouse(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastError = "CGEvent.tapCreate returned nil — grant Accessibility permission"
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        isRunning = false
        activeWindowID = nil
        activeInteraction = nil
        pressIsGesture = false
        mouseIsDown = false
    }

    // MARK: - Event handling

    fileprivate func handleMouse(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            mouseIsDown = true
            pressIsGesture = false
            pressLocation = event.location
            activeWindowID = nil
            activeInteraction = nil

            guard let hit = hitTestWindow(at: event.location) else { return }
            switch hit.interaction {
            case .drag, .resize:
                activeWindowID = hit.windowID
                activeInteraction = hit.interaction
            case .body:
                break
            }

        case .leftMouseDragged:
            guard mouseIsDown, activeWindowID != nil else { return }
            guard !pressIsGesture else { return }
            let travel = hypot(event.location.x - pressLocation.x,
                               event.location.y - pressLocation.y)
            if travel >= dragActivationDistance {
                pressIsGesture = true
            }

        case .leftMouseUp:
            mouseIsDown = false
            pressIsGesture = false
            activeWindowID = nil
            activeInteraction = nil

        default:
            break
        }
    }

    private struct Hit {
        let windowID: CGWindowID
        let interaction: WindowInteraction
    }

    /// Finds the topmost tracked window under `point` that the press could act
    /// on. Windows whose press lands in the body are skipped, so clicking into a
    /// window that happens to overlap another one does not start a trail.
    private func hitTestWindow(at point: CGPoint) -> Hit? {
        for entry in orderedFrames {
            guard let interaction = WindowInteractionTester.interaction(at: point, in: entry.frame),
                  interaction != .body
            else { continue }
            return Hit(windowID: entry.id, interaction: interaction)
        }
        return nil
    }
}