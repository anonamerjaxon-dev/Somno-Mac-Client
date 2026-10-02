import Foundation
import CoreGraphics

public enum OverlapResolver {

    public static func detectOverlaps(in canvases: [CanvasModel]) -> [(UUID, UUID)] {
        var overlaps: [(UUID, UUID)] = []
        for i in 0..<canvases.count {
            for j in (i + 1)..<canvases.count {
                if canvases[i].frame.intersects(canvases[j].frame) {
                    overlaps.append((canvases[i].id, canvases[j].id))
                }
            }
        }
        return overlaps
    }

    public static func resolve(
        moving: CanvasModel,
        against others: [CanvasModel],
        preferredDirection: CGVector = .zero
    ) -> CGRect {
        resolve(moving: moving.frame, excluding: moving.id, against: others, preferredDirection: preferredDirection)
    }

    /// Resolves a candidate frame that is not (yet) part of `against`.
    ///
    /// The editor calls this on every mouse-moved while dragging, with a frame
    /// built from the drag so far, so the moving canvas does not have to be
    /// written back into the model first.
    public static func resolve(
        moving frame: CGRect,
        excluding movingID: UUID,
        against others: [CanvasModel],
        preferredDirection: CGVector = .zero
    ) -> CGRect {
        var resolved = frame
        let others = others.filter { $0.id != movingID }

        for other in others {
            guard resolved.intersects(other.frame) else { continue }

            let pushRight = other.frame.maxX - resolved.minX + 1
            let pushLeft = resolved.maxX - other.frame.minX + 1
            let pushUp = other.frame.maxY - resolved.minY + 1
            let pushDown = resolved.maxY - other.frame.minY + 1

            var pushes: [(CGFloat, CGVector)] = [
                (pushRight, CGVector(dx: 1, dy: 0)),
                (pushLeft, CGVector(dx: -1, dy: 0)),
                (pushUp, CGVector(dx: 0, dy: 1)),
                (pushDown, CGVector(dx: 0, dy: -1)),
            ]

            pushes.sort { a, b in
                let aDot = a.1.dx * preferredDirection.dx + a.1.dy * preferredDirection.dy
                let bDot = b.1.dx * preferredDirection.dx + b.1.dy * preferredDirection.dy
                if aDot != bDot { return aDot > bDot }
                return a.0 < b.0
            }

            resolved.origin.x += pushes[0].1.dx * pushes[0].0
            resolved.origin.y += pushes[0].1.dy * pushes[0].0
        }

        return resolved
    }

    public enum ValidationError: Error, LocalizedError {
        case overlappingCanvases([(UUID, UUID)])

        public var errorDescription: String? {
            switch self {
            case .overlappingCanvases(let pairs):
                let listed = pairs
                    .map { "\($0.0.uuidString) \($0.1.uuidString)" }
                    .joined(separator: ", ")
                return "Layout contains \(pairs.count) overlapping canvas pair(s): \(listed)"
            }
        }
    }

    public static func validate(_ canvases: [CanvasModel]) throws {
        let overlaps = detectOverlaps(in: canvases)
        if !overlaps.isEmpty {
            throw ValidationError.overlappingCanvases(overlaps)
        }
    }
}