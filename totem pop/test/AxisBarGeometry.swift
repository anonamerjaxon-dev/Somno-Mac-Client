import Foundation
import CoreGraphics

// MARK: - Axis bar geometry

/// Geometry for the centred value bar under each axis.
///
/// Extracted as a pure value type so `runSelfTest()` can verify the anchoring
/// arithmetic without a window or a live sensor.
///
/// The bar is drawn inside a ZStack whose centre is the zero marker. A bar of
/// width `w` offset by `d` therefore occupies `[d - w/2, d + w/2]`. For a
/// positive value we want it to start exactly at the marker (`d - w/2 == 0`)
/// and extend right, so `d == w/2`. The previous code offset by the full
/// magnitude, producing `[0.5v, 1.5v] × (150/maxG)` — it started at half the
/// value and overshot the mapped maximum by 50%.
struct AxisBarGeometry {
    /// Display range in g. The track maps `-maxG … +maxG` onto `-halfWidth … +halfWidth`.
    let maxG: Double
    /// Half the track width in points: the bar for a full-scale reading
    /// (`value == maxG`) spans from the marker to this point.
    let halfWidth: CGFloat
    /// Thin bar is always at least this wide so a value of exactly 0 is visible.
    let minWidth: CGFloat

    init(maxG: Double = 2.0, halfWidth: CGFloat = 150, minWidth: CGFloat = 2) {
        self.maxG = maxG
        self.halfWidth = halfWidth
        self.minWidth = minWidth
    }

    /// Value clamped to the display range.
    func clamped(_ value: Double) -> Double {
        min(max(value, -maxG), maxG)
    }

    /// Length of the bar in points. Zero maps to `minWidth`.
    func width(for value: Double) -> CGFloat {
        max(minWidth, abs(CGFloat(clamped(value)) / maxG) * halfWidth)
    }

    /// X offset from the ZStack centre.
    ///
    /// Half the width for positive values (so the bar starts at the marker),
    /// negated half the width for negative values (so it starts at the marker
    /// and extends left).
    func offset(for value: Double) -> CGFloat {
        let w = width(for: value)
        return clamped(value) >= 0 ? w / 2 : -w / 2
    }

    /// The bar's leading edge, in points from the track's centre.
    /// Always 0 for any value — the anchoring invariant the self-test asserts.
    func leadingEdge(for value: Double) -> CGFloat {
        offset(for: value) - width(for: value) / 2
    }

    /// The bar's trailing edge, in points from the track's centre.
    func trailingEdge(for value: Double) -> CGFloat {
        offset(for: value) + width(for: value) / 2
    }
}

