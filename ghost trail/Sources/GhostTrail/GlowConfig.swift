import SwiftUI

/// A soft halo applied to the ribbon. Kept intentionally cheap: the whole
/// ribbon is blurred once, rather than once per frame as the previous renderer
/// did, because a per-frame blur is what made the trail expensive to draw.
public struct GlowConfig: Sendable, Equatable {
    /// Blur radius in points.
    public var radius: CGFloat
    /// Strength multiplier applied on top of the configuration's opacity.
    public var intensity: Double
    /// Optional override colour; the trail's own colour is used when `nil`.
    public var color: Color?

    public init(radius: CGFloat, intensity: Double, color: Color? = nil) {
        self.radius = max(radius, 0)
        self.intensity = max(min(intensity, 1), 0)
        self.color = color
    }
}