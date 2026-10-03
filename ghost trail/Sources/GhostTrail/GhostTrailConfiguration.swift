import SwiftUI

/// Where the trail overlay sits relative to ordinary application windows.
public enum TrailWindowLevel: Sendable {
    /// Above every normal window: the trail is never occluded.
    case aboveWindows
    /// Directly above the desktop icons and far below `kCGNormalWindowLevel`, so
    /// the window being dragged covers the part of the trail it overlaps.
    case behindWindows
}

public struct GhostTrailConfiguration: Sendable {
    public var strokeColor: TrailColor
    public var strokeWidth: CGFloat
    /// Maximum number of recorded samples retained per window. The ribbon is
    /// interpolated between them, so this bounds memory, not visual smoothness.
    public var frameCount: Int
    /// Seconds for an abandoned trail to dissolve completely.
    public var fadeDuration: TimeInterval
    /// Smallest movement or resize, in points, worth recording.
    public var movementThreshold: CGFloat
    /// Movement or resize beyond this, in points, in one poll is treated as a
    /// window snap (tiling, Space change, Stage Manager) and restarts the trail.
    public var snapDistance: CGFloat
    public var opacity: Double
    /// Fraction of the ribbon, from the tail, over which the gradient ramps up
    /// from nothing. `0` ramps across the whole ribbon; `0.6` keeps the back
    /// third invisible and fades through the rest.
    public var tailFadeStart: Double
    public var glow: GlowConfig?
    public var cornerRadius: CGFloat
    public var windowLevel: TrailWindowLevel

    public init(
        strokeColor: TrailColor = .solid(.white),
        strokeWidth: CGFloat = 2,
        frameCount: Int = 48,
        fadeDuration: TimeInterval = 0.9,
        movementThreshold: CGFloat = 1.5,
        snapDistance: CGFloat = 48,
        opacity: Double = 0.75,
        tailFadeStart: Double = 0.35,
        glow: GlowConfig? = nil,
        cornerRadius: CGFloat = 10,
        windowLevel: TrailWindowLevel = .behindWindows
    ) {
        self.strokeColor = strokeColor
        self.strokeWidth = max(strokeWidth, 0.5)
        self.frameCount = max(frameCount, 2)
        self.fadeDuration = max(fadeDuration, 0.05)
        self.movementThreshold = max(movementThreshold, 0.1)
        self.snapDistance = max(snapDistance, self.movementThreshold)
        self.opacity = max(min(opacity, 1), 0)
        self.tailFadeStart = max(min(tailFadeStart, 1), 0)
        self.glow = glow
        self.cornerRadius = max(cornerRadius, 0)
        self.windowLevel = windowLevel
    }

    /// Capacity the history buffer is created with, from `frameCount`.
    public var historyCapacity: Int { frameCount }

    /// Quiet and short. Nearly invisible unless dragged quickly.
    public static let subtle = GhostTrailConfiguration(
        strokeColor: .solid(.white),
        strokeWidth: 1,
        frameCount: 36,
        fadeDuration: 0.55,
        movementThreshold: 2,
        snapDistance: 48,
        opacity: 0.35,
        tailFadeStart: 0.45,
        cornerRadius: 10
    )

    /// Bright, long, with a glow. Reads clearly even on a busy desktop.
    public static let dramatic = GhostTrailConfiguration(
        strokeColor: .solid(.white),
        strokeWidth: 3,
        frameCount: 64,
        fadeDuration: 1.2,
        movementThreshold: 1,
        snapDistance: 64,
        opacity: 0.9,
        tailFadeStart: 0.2,
        glow: GlowConfig(radius: 10, intensity: 0.55),
        cornerRadius: 10
    )

    public static let retro = GhostTrailConfiguration(
        strokeColor: .solid(.green),
        strokeWidth: 2,
        frameCount: 48,
        fadeDuration: 0.8,
        movementThreshold: 1,
        snapDistance: 48,
        opacity: 0.7,
        tailFadeStart: 0.3,
        cornerRadius: 10
    )

    public static let neon = GhostTrailConfiguration(
        strokeColor: .gradient(.cyan, .purple),
        strokeWidth: 2,
        frameCount: 56,
        fadeDuration: 1.0,
        movementThreshold: 1,
        snapDistance: 56,
        opacity: 0.9,
        tailFadeStart: 0.25,
        glow: GlowConfig(radius: 14, intensity: 0.7, color: .cyan),
        cornerRadius: 10
    )

    public static let glass = GhostTrailConfiguration(
        strokeColor: .solid(.white),
        strokeWidth: 1,
        frameCount: 72,
        fadeDuration: 1.4,
        movementThreshold: 1,
        snapDistance: 48,
        opacity: 0.28,
        tailFadeStart: 0.5,
        glow: GlowConfig(radius: 7, intensity: 0.2, color: .white),
        cornerRadius: 14
    )
}