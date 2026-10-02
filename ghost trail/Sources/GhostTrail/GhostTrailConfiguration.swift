import SwiftUI

public enum TrailWindowLevel: Sendable {
    case aboveWindows
    case behindWindows
}

public struct GhostTrailConfiguration: Sendable {
    public var strokeColor: TrailColor
    public var strokeWidth: CGFloat
    public var frameCount: Int
    public var fadeDuration: TimeInterval
    public var movementThreshold: CGFloat
    /// Position delta above which a window is treated as having jumped (teleported)
    /// rather than been dragged, so its stale trail is discarded.
    public var jumpThreshold: CGFloat
    public var opacity: Double
    public var style: TrailStyle
    public var glow: GlowConfig?
    public var cornerRadius: CGFloat
    public var windowLevel: TrailWindowLevel

    public init(
        strokeColor: TrailColor = .solid(.white),
        strokeWidth: CGFloat = 2,
        frameCount: Int = 20,
        fadeDuration: TimeInterval = 1.5,
        movementThreshold: CGFloat = 1,
        jumpThreshold: CGFloat = 200,
        opacity: Double = 0.8,
        style: TrailStyle = .outline,
        glow: GlowConfig? = nil,
        cornerRadius: CGFloat = 8,
        windowLevel: TrailWindowLevel = .behindWindows
    ) {
        self.strokeColor = strokeColor
        self.strokeWidth = max(strokeWidth, 0.5)
        self.frameCount = max(frameCount, 10)
        self.fadeDuration = max(fadeDuration, 0.1)
        self.movementThreshold = max(movementThreshold, 1)
        self.jumpThreshold = max(jumpThreshold, 1)
        self.opacity = max(min(opacity, 1.0), 0.0)
        self.style = style
        self.glow = glow
        self.cornerRadius = max(cornerRadius, 0)
        self.windowLevel = windowLevel
    }

    public static let subtle = GhostTrailConfiguration(
        strokeColor: .solid(.white.opacity(0.4)),
        strokeWidth: 1,
        frameCount: 15,
        fadeDuration: 0.5,
        movementThreshold: 2,
        opacity: 0.4,
        cornerRadius: 8
    )

    public static let dramatic = GhostTrailConfiguration(
        strokeColor: .solid(.white),
        strokeWidth: 3,
        frameCount: 30,
        fadeDuration: 1.2,
        movementThreshold: 1,
        opacity: 0.85,
        style: .solid,
        glow: GlowConfig(radius: 8, intensity: 0.5),
        cornerRadius: 8
    )

    public static let retro = GhostTrailConfiguration(
        strokeColor: .solid(.green),
        strokeWidth: 2,
        frameCount: 20,
        fadeDuration: 0.8,
        movementThreshold: 1,
        opacity: 0.7,
        cornerRadius: 8
    )

    public static let neon = GhostTrailConfiguration(
        strokeColor: .solid(.cyan),
        strokeWidth: 2,
        frameCount: 25,
        fadeDuration: 1.0,
        movementThreshold: 1,
        opacity: 0.9,
        style: .solid,
        glow: GlowConfig(radius: 12, intensity: 0.7, color: .cyan),
        cornerRadius: 8
    )

    public static let glass = GhostTrailConfiguration(
        strokeColor: .solid(.white.opacity(0.2)),
        strokeWidth: 1,
        frameCount: 35,
        fadeDuration: 1.5,
        movementThreshold: 1,
        opacity: 0.3,
        style: .solid,
        glow: GlowConfig(radius: 6, intensity: 0.15, color: .white),
        cornerRadius: 12
    )
}