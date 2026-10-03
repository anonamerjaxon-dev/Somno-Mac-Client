import Foundation
import CoreGraphics
import AppKit

/// Tracks every on-screen window and decides, per poll, which of them should be
/// drawing a trail.
///
/// Two things changed from the previous tracker, both driven by the fact that a
/// window's *rectangle* is not a point:
///
/// 1. **Size is compared alongside origin.** Comparing origins only meant a
///    window being resized — origin unchanged — was indistinguishable from a
///    window sitting still, and produced no trail at all.
/// 2. **More than one window can be trailed at once.** The old tracker picked
///    the single most-recently-moved window and deleted every other window's
///    history, so dragging two windows concurrently kept exactly one trail.
///
/// Which windows are *eligible* is decided by `DragSessionTracker` from real
/// mouse events; this type does the geometry work.
final class WindowTracker {
    private var histories: [CGWindowID: RingBuffer<TrailSample>] = [:]
    private var lastSamples: [CGWindowID: TrailSample] = [:]
    private var lastMoved: [CGWindowID: CFTimeInterval] = [:]
    private let tuning: TrailTuning
    private let historyCapacity: Int
    private let fadeDuration: TimeInterval
    private let ownPID: Int32

    init(historyCapacity: Int, fadeDuration: TimeInterval, tuning: TrailTuning = TrailTuning()) {
        self.historyCapacity = max(historyCapacity, 2)
        self.fadeDuration = max(fadeDuration, 0.05)
        self.tuning = tuning
        self.ownPID = ProcessInfo.processInfo.processIdentifier
    }

    /// Windows that appeared since the last poll, which the eligibility layer
    /// needs in order to map a mouse-down location to a window.
    func takeNewlySeenWindowIDs() -> Set<CGWindowID> {
        defer { newlySeen.removeAll() }
        return newlySeen
    }

    private var newlySeen: Set<CGWindowID> = []

    /// Snapshots the on-screen window list. Split out so the decision logic can
    /// be tested against fixed input.
    func poll(eligible: Set<CGWindowID>, now: CFTimeInterval) -> [CGWindowID: RingBuffer<TrailSample>] {
        let windows = Self.currentWindowFrames(excludingPID: ownPID)
        let onScreen = Set(windows.keys)

        var result: [CGWindowID: RingBuffer<TrailSample>] = [:]

        for (id, frame) in windows {
            let current = TrailSample(frame: frame, timestamp: now)

            guard eligible.contains(id) else {
                // A window that is no longer being touched stops contributing
                // samples, but keeps its history so the ribbon can finish fading.
                lastSamples[id] = current
                continue
            }

            guard let previous = lastSamples[id] else {
                lastSamples[id] = current
                newlySeen.insert(id)
                continue
            }

            switch tuning.classify(current, from: previous) {
            case .stationary:
                lastSamples[id] = current

            case .continuous:
                append(id, current)
                lastSamples[id] = current
                lastMoved[id] = now

            case .snapped:
                // A tiled/snapped window has genuinely been somewhere else.
                // Restarting the ribbon from the new position is correct: a
                // connecting line would be a lie about the motion.
                histories[id] = nil
                append(id, current)
                lastSamples[id] = current
                lastMoved[id] = now
            }

            if let buffer = histories[id] {
                result[id] = buffer
            }
        }

        expire(id: eligible, onScreen: onScreen, now: now, into: &result)
        return result
    }

    /// Drops history for windows that can no longer contribute, and lets the
    /// trails of windows that merely stopped moving keep fading.
    private func expire(id: Set<CGWindowID>, onScreen: Set<CGWindowID>, now: CFTimeInterval, into result: inout [CGWindowID: RingBuffer<TrailSample>]) {
        for (trackedID, buffer) in histories {
            let stillTracked = id.contains(trackedID)
            let stillOnScreen = onScreen.contains(trackedID)
            let recentlyMoved = now - (lastMoved[trackedID] ?? 0) <= fadeDuration

            if !stillOnScreen || (!stillTracked && !recentlyMoved) {
                histories[trackedID] = nil
                lastSamples[trackedID] = nil
                lastMoved[trackedID] = nil
                continue
            }

            // Keep only samples that are still inside the fade window, so the
            // ribbon shortens over time instead of the renderer alpha-fading a
            // trail whose tail is already invisible.
            var kept = buffer
            while let oldest = kept.first, now - oldest.timestamp >= fadeDuration {
                kept.removeFirst()
            }
            if kept.isEmpty {
                histories[trackedID] = nil
                lastSamples[trackedID] = nil
                lastMoved[trackedID] = nil
                continue
            }
            histories[trackedID] = kept
            result[trackedID] = kept
        }

        for staleID in lastSamples.keys where !onScreen.contains(staleID) {
            lastSamples[staleID] = nil
        }
    }

    private func append(_ id: CGWindowID, _ sample: TrailSample) {
        if histories[id] == nil {
            histories[id] = ring(capacity: historyCapacity)
        }
        histories[id]?.append(sample)
    }

    private func ring(capacity: Int) -> RingBuffer<TrailSample> {
        RingBuffer<TrailSample>(capacity: capacity)
    }

    func clearAll() {
        histories.removeAll()
        lastSamples.removeAll()
        lastMoved.removeAll()
        newlySeen.removeAll()
    }

    /// All visible, non-overlay windows owned by other processes, keyed by
    /// window ID.
    ///
    /// Layer filtering is the interesting part. Layer 0 holds ordinary document
    /// and application windows. Layers above it hold panels, sheets, popovers,
    /// menus and tooltips, which follow their parent around during a drag and
    /// would otherwise smear a trail of their own. Windows belonging to this
    /// process are excluded so the overlay never trails itself.
    static func currentWindowFrames(excludingPID pid: Int32) -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var frames: [CGWindowID: CGRect] = [:]
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32, ownerPID != pid else { continue }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X" as String] as? CGFloat,
                  let y = bounds["Y" as String] as? CGFloat,
                  let width = bounds["Width" as String] as? CGFloat,
                  let height = bounds["Height" as String] as? CGFloat
            else { continue }
            guard width > 0, height > 0 else { continue }

            frames[id] = CGRect(x: x, y: y, width: width, height: height)
        }
        return frames
    }
}