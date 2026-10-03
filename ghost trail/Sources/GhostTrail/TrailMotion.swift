import Foundation
import CoreGraphics
import AppKit

/// One observation of a window's geometry, in the same Quartz-global space
/// `CGWindowListCopyWindowInfo` reports (top-left origin, `+y` down).
///
/// Size is compared as well as origin, because a window that is being resized
/// and not moved produces no origin delta at all — the old tracker compared
/// origins only and therefore never drew a trail for a resize.
struct TrailSample: Equatable {
    let frame: CGRect
    let timestamp: CFTimeInterval

    /// Origin delta from `other`, ignoring size.
    func originDelta(from other: TrailSample) -> CGFloat {
        hypot(frame.minX - other.frame.minX, frame.minY - other.frame.minY)
    }

    /// Size delta from `other`, ignoring origin.
    func sizeDelta(from other: TrailSample) -> CGFloat {
        hypot(frame.width - other.frame.width, frame.height - other.frame.height)
    }
}

/// How a tracked window's motion is classified. The distinction matters because
/// a snapped window teleports and an ordinary drag does not — drawing a
/// continuous ribbon across a 2,000pt teleport produces a stripe across the
/// whole screen, which is exactly the artifact the old clear-on-jump logic
/// avoided by throwing the trail away.
enum MotionKind: Equatable {
    /// Moved less than the snap distance: part of a continuous gesture.
    case continuous
    /// Origin or size changed by more than `snapDistance` in one poll. macOS
    /// window tiling, Space switches, Stage Manager regrouping and display
    /// reconfiguration all land here.
    case snapped
    /// Motion smaller than `minDistance`: the pointer jitters, or the window is
    /// animating itself. Ignored rather than recorded.
    case stationary
}

/// What the renderer should do with the history of one window.
enum TrailLifecycle: Equatable {
    /// Still being dragged: emit samples as they arrive.
    case active
    /// Gesture ended. The trail must finish fading on its own, so the window is
    /// retained until the ribbon has expired.
    case fading(sinceExpire: TimeInterval)
    /// The window closed, minimized, or changed identity. Drop immediately.
    case dead
}

/// The decision made for one window in one poll, derived purely from its
/// previous and current sample. Kept separate from `WindowTracker` so it can be
/// tested without a live window server.
struct TrailDecision: Equatable {
    let windowID: CGWindowID
    let kind: MotionKind
    let lifecycle: TrailLifecycle
    /// The sample to append to the ribbon, or `nil` to record nothing.
    let append: TrailSample?
    /// Replace the whole history rather than appending — used after a snap.
    let resetHistory: Bool
}

/// Moves a rect by the largest component-wise distance between the two.
extension CGRect {
    func hypotDistance(to other: CGRect) -> CGFloat {
        hypot(minX - other.minX, minY - other.minY) + hypot(width - other.width, height - other.height)
    }
}

struct TrailTuning: Equatable {
    /// Smallest movement or resize worth recording, in points. Below this the
    /// window is considered stationary. Guards against pointer jitter producing
    /// hundreds of identical samples a second.
    var minDistance: CGFloat
    /// Movement or resize beyond this, in points, within a single poll is a
    /// snap rather than a drag.
    var snapDistance: CGFloat

    init(minDistance: CGFloat = 1.5, snapDistance: CGFloat = 48) {
        self.minDistance = max(minDistance, 0.1)
        self.snapDistance = max(snapDistance, self.minDistance)
    }

    func classify(_ current: TrailSample, from previous: TrailSample) -> MotionKind {
        // Translation and resize are judged separately, and only translation can
        // be a snap. The two thresholds are in different units: a 60pt movement
        // between two 30Hz samples is a fast flick, but a 60pt *resize* is
        // someone dragging a window edge, and treating it as a snap threw away
        // the trail on every fast resize.
        let move = current.originDelta(from: previous)
        if move >= snapDistance { return .snapped }

        let travel = max(move, current.sizeDelta(from: previous))
        if travel >= minDistance { return .continuous }
        return .stationary
    }
}