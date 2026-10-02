import Foundation
import CoreGraphics
import QuartzCore

final class WindowTracker {
    private var windowTrails: [CGWindowID: RingBuffer<TrailFrame>] = [:]
    private var lastKnownFrames: [CGWindowID: NSRect] = [:]
    private var lastMovedTime: [CGWindowID: CFTimeInterval] = [:]
    private let frameCount: Int
    private let fadeDuration: TimeInterval
    private let movementThreshold: CGFloat
    private let jumpThreshold: CGFloat
    private let ownPID: Int32

    init(
        frameCount: Int,
        fadeDuration: TimeInterval,
        movementThreshold: CGFloat = 1,
        jumpThreshold: CGFloat = 200
    ) {
        self.frameCount = frameCount
        self.fadeDuration = fadeDuration
        self.movementThreshold = max(movementThreshold, 1)
        self.jumpThreshold = max(jumpThreshold, 1)
        self.ownPID = ProcessInfo.processInfo.processIdentifier
    }

    func poll() -> [CGWindowID: RingBuffer<TrailFrame>] {
        let now = CACurrentMediaTime()

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return windowTrails
        }

        var activeWindowIDs = Set<CGWindowID>()
        var activeMoveWindowID: CGWindowID?
        var activeMoveTime: CFTimeInterval = 0

        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer <= 1 else { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  let windowID = w[kCGWindowNumber as String] as? CGWindowID else { continue }

            let currentFrame = NSRect(x: x, y: y, width: width, height: height)
            activeWindowIDs.insert(windowID)

            if let lastFrame = lastKnownFrames[windowID] {
                let dx = abs(currentFrame.origin.x - lastFrame.origin.x)
                let dy = abs(currentFrame.origin.y - lastFrame.origin.y)
                let jumped = dx > jumpThreshold || dy > jumpThreshold

                if jumped {
                    windowTrails[windowID]?.clear()
                } else if dx >= movementThreshold || dy >= movementThreshold {
                    appendFrame(windowID,
                                frame: lastFrame,
                                now: now)
                    lastMovedTime[windowID] = now
                }

                if let movedAt = lastMovedTime[windowID], movedAt > activeMoveTime {
                    activeMoveTime = movedAt
                    activeMoveWindowID = windowID
                }

                lastKnownFrames[windowID] = currentFrame
            } else {
                lastKnownFrames[windowID] = currentFrame
            }
        }

        pruneStaleWindows(activeIDs: activeWindowIDs, now: now)

        if let activeID = activeMoveWindowID {
            for id in windowTrails.keys where id != activeID {
                windowTrails.removeValue(forKey: id)
                lastKnownFrames.removeValue(forKey: id)
                lastMovedTime.removeValue(forKey: id)
            }
            return [activeID: windowTrails[activeID] ?? RingBuffer<TrailFrame>(capacity: frameCount)]
        }
        windowTrails.removeAll()
        return [:]
    }

    func stopTracking(windowID: CGWindowID) {
        windowTrails.removeValue(forKey: windowID)
        lastKnownFrames.removeValue(forKey: windowID)
        lastMovedTime.removeValue(forKey: windowID)
    }

    func clearAll() {
        windowTrails.removeAll()
        lastKnownFrames.removeAll()
        lastMovedTime.removeAll()
    }

    private func appendFrame(_ windowID: CGWindowID, frame: NSRect, now: CFTimeInterval) {
        var trail = windowTrails[windowID]
            ?? RingBuffer<TrailFrame>(capacity: frameCount)

        if let last = trail.last {
            let dx = abs(frame.origin.x - last.frame.origin.x)
            let dy = abs(frame.origin.y - last.frame.origin.y)
            guard dx >= movementThreshold || dy >= movementThreshold else { return }
        }

        trail.append(TrailFrame(frame: frame, timestamp: now))
        windowTrails[windowID] = trail
    }

    private func pruneStaleWindows(activeIDs: Set<CGWindowID>, now: CFTimeInterval) {
        var stale = Set(windowTrails.keys).subtracting(activeIDs)
        for id in windowTrails.keys where !activeIDs.contains(id) {
            stale.insert(id)
        }

        let expired = windowTrails.keys.filter { id in
            if let movedAt = lastMovedTime[id] {
                return now - movedAt > fadeDuration
            }
            return !activeIDs.contains(id)
        }

        stale.formUnion(expired)

        for id in stale {
            windowTrails.removeValue(forKey: id)
            lastKnownFrames.removeValue(forKey: id)
            lastMovedTime.removeValue(forKey: id)
        }
    }
}