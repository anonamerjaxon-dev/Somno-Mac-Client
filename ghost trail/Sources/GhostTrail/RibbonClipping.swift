import AppKit
import SwiftUI
import CoreGraphics

/// Cuts holes in the ribbon so it can appear to pass *behind* real windows.
///
/// ## Why this exists
///
/// The overlay cannot use z-order to sit behind application windows. macOS
/// composites nothing below `kCGNormalWindowLevel` — measured, not assumed: a
/// 400×200pt window at `kCGDesktopIconWindowLevel`, at `normal - 1`, and at
/// every level in between produced 475 pixels in a screenshot, identical to an
/// off-screen baseline, while the same window at `kCGNormalWindowLevel` produced
/// 320,475. (It makes no difference whether the process is `.accessory` or
/// `.regular`.) So `GhostTrailWindow` puts the overlay one point *above* normal
/// windows, and the depth illusion is drawn rather than composited.
///
/// ## How
///
/// `GraphicsContext.clip(to:style:)` intersects a region; it cannot subtract
/// one. Holes are therefore expressed as a single **even-odd clip region** — one
/// enclosing rectangle with the hole rectangles nested inside it — which leaves
/// exactly the ring between them. Appending the hole rects to the ribbon path
/// itself, and filling even-odd, is the obvious alternative and is wrong; see
/// `fill(_:path:holes:with:)` for the measurement.
enum RibbonClipping {
    /// Fills `path` with `shading`, excluding `holes`.
    ///
    /// The holes are expressed as a **clip**, not as extra subpaths. That is not
    /// a stylistic choice: the ribbon path is one subpath per interpolated
    /// section, and consecutive sections overlap heavily. Appending hole rects
    /// and filling even-odd therefore counts crossings for the ribbon itself —
    /// a point inside two overlapping sections has two crossings and comes out
    /// *unfilled*. The ribbon ends up shredded, and worse, a full-screen occluder
    /// turns every one of those shredded regions back *on* (three crossings,
    /// odd), so occluding more restores pixels. Measured: 18,210 pixels survived
    /// an occluder that covered the entire screen.
    ///
    /// A clip is a region, intersected rather than parity-counted, so overlapping
    /// ribbon sections stay solid while the holes are genuinely excluded.
    static func fill(
        _ context: GraphicsContext,
        path: Path,
        holes: [CGRect],
        with shading: GraphicsContext.Shading
    ) {
        // No holes, no clip. Clipping to a region that contains everything still
        // costs a resampling pass, and the clip's own antialiased edge then eats
        // into the ribbon: measured 4,614 of accumulated alpha missing from a
        // ribbon that was never occluded at all.
        guard !holes.isEmpty else {
            context.fill(path, with: shading)
            return
        }
        var clipped = context
        if let clip = clipRegion(of: holes, around: path) {
            clipped.clip(to: clip, style: FillStyle(eoFill: true))
        }
        clipped.fill(path, with: shading)
    }

    /// Strokes `path`, clipped to exclude `holes`.
    ///
    /// Same construction as `fill`. The clip rect is inflated by `pad` so a wide
    /// stroke, its round joins and the glow's blur all stay inside the ring
    /// instead of being guillotined at the clip boundary.
    static func stroke(
        _ context: GraphicsContext,
        path: Path,
        holes: [CGRect],
        with shading: GraphicsContext.Shading,
        lineWidth: CGFloat
    ) {
        guard !holes.isEmpty else {
            context.stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
            return
        }
        var clipped = context
        if let clip = clipRegion(of: holes, around: path, padding: lineWidth * 2 + 8) {
            clipped.clip(to: clip, style: FillStyle(eoFill: true))
        }
        clipped.stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    /// The region around `path` with every rect in `holes` removed.
    ///
    /// One enclosing subpath plus one nested subpath per hole, filled even-odd,
    /// leaves exactly the ring between them.
    ///
    /// The enclosing subpath is pushed well outside the geometry rather than
    /// matching `path.boundingRect` exactly. A clip edge is antialiased, so an
    /// enclosing edge that coincides with the ribbon's own bounding box strips a
    /// half-covered fringe off the ribbon's extremes — measured as 4,614 of
    /// accumulated alpha missing from a ribbon that was never occluded at all.
    /// Only the *hole* edges should ever be visible, and those are meant to be:
    /// a window's edge is a hard boundary, and a one-pixel feather there is what
    /// stops the ribbon from looking chopped out with scissors.
    static func clipRegion(of holes: [CGRect], around path: Path, padding: CGFloat = 0) -> Path? {
        let bounds = path.boundingRect.insetBy(dx: -(padding + outerMargin), dy: -(padding + outerMargin))
        guard !bounds.isEmpty else { return nil }
        var clip = Path()
        clip.addRect(bounds)
        for hole in holes where !hole.isEmpty {
            clip.addRect(hole)
        }
        return clip
    }

    /// How far outside the drawn geometry the clip's enclosing subpath sits.
    /// Far past any display's size, so the edge is never in frame.
    private static let outerMargin: CGFloat = 4096
}