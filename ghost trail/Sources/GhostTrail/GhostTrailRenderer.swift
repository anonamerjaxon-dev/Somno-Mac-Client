import AppKit
import SwiftUI
import QuartzCore

/// Draws one window's history as a single swept ribbon.
///
/// The previous implementation stroked one rectangle per recorded frame. Where
/// frames overlapped — which is everywhere, during a slow drag — their alphas
/// accumulated, so the trail read as a flat grey smudge instead of motion. This
/// builds one path by sweeping a rectangle along the trail's centre line and
/// filling it with a gradient, so overlapping geometry never stacks alpha.
final class GhostTrailRenderer {
    private let configuration: GhostTrailConfiguration

    init(configuration: GhostTrailConfiguration) {
        self.configuration = configuration
    }

    /// Draws every trail in `trails`.
    ///
    /// `now` is a parameter rather than a call to `CACurrentMediaTime()` so the
    /// renderer can be rasterised twice and compared exactly. The ribbon's alpha
    /// ramps by age, so a renderer's output is a function of the clock: measured
    /// over three renders of identical geometry, accumulated alpha moved
    /// 5,263,122 → 5,201,486 → 5,157,020 — about 0.9% — purely because each
    /// render ran a few milliseconds later. Any test that pins a pixel value
    /// therefore has to pin the clock too.
    func draw(
        context: GraphicsContext,
        trails: [CGWindowID: RingBuffer<TrailSample>],
        occluders: [CGRect],
        size: CGSize,
        converter: TrailCoordinateConverter = .identity,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        // Occluders arrive in overlay-view coordinates; the ribbon is built in
        // the same space, so they can be tested against it directly.
        for (_, samples) in trails {
            let sections = RibbonGeometry.sections(
                for: samples,
                now: now,
                convert: { converter.viewRect(fromQuartz: $0) },
                cornerRadius: configuration.cornerRadius
            )
            guard sections.count >= 2 else { continue }

            let path = Self.ribbonPath(for: sections)
            guard !path.isEmpty else { continue }

            drawRibbon(context: context, path: path, sections: sections,
                       occluders: occluders, now: now)
        }
    }

    // MARK: - Ribbon path

    /// Sweeps the window's rectangle along the trail.
    ///
    /// The four corners of every recorded rectangle are concatenated in trail
    /// order into one region, so the filled area is the whole swath the window
    /// covered. Because it is a single fill whose alpha comes from a gradient
    /// rather than from one stroke per frame, overlapping parts of the path
    /// cannot compound into a brighter patch — which is exactly what turned the
    /// old stacked-rectangle trail into a grey smudge.
    static func ribbonPath(for sections: [RibbonSection]) -> Path {
        guard let first = sections.first else { return Path() }
        _ = first

        var path = Path()
        var isFirstSection = true

        for section in sections {
            let rect = section.rect
            let topLeft = CGPoint(x: rect.minX, y: rect.maxY)
            let topRight = CGPoint(x: rect.maxX, y: rect.maxY)
            let bottomRight = CGPoint(x: rect.maxX, y: rect.minY)
            let bottomLeft = CGPoint(x: rect.minX, y: rect.minY)

            if isFirstSection {
                path.move(to: topLeft)
                isFirstSection = false
            } else {
                // Close the gap between the previous rectangle and this one so
                // the ribbon has no holes at high pointer speeds.
                path.addLine(to: topLeft)
            }

            path.addLine(to: topRight)
            path.addLine(to: bottomRight)
            path.addLine(to: bottomLeft)
            path.closeSubpath()
        }

        return path
    }

    // MARK: - Painting

    private func drawRibbon(context: GraphicsContext, path: Path, sections: [RibbonSection], occluders: [CGRect], now: CFTimeInterval) {
        let oldest = sections[0]
        let newest = sections[sections.count - 1]
        let tint = leadingColor(at: newest, oldest: oldest, now: now)

        let stops = gradientStops(for: sections, now: now)
        let gradient = Gradient(stops: stops)

        // The overlay has to sit above application windows, because macOS draws
        // nothing below `kCGNormalWindowLevel` (measured — see `RibbonClipping`).
        // Depth is therefore drawn: the ribbon is filled with the window frames
        // punched out of it, so the part the dragged window covers is simply not
        // painted and the desktop shows through, exactly as if the ribbon really
        // were underneath.
        //
        // Two adjustments, both needed to erase ink that lies *outside* the
        // windows' own frames:
        //
        //  - `slop` widens each hole, so the head outline's outer half — a
        //    stroke centred on the window's rectangle — is covered too. Without
        //    it a bright outline is drawn straight across the occluding window's
        //    face: measured 1,836 pixels, the exact failure this whole mechanism
        //    exists to prevent.
        //
        //  - the reference rect is the *drawn* extent, not the body extent.
        //    `occludingRects` intersects each hole with it, so measuring against
        //    the body bounds silently trims a hole that covers everything back
        //    down to the body — leaving 250 pixels of head stroke surviving a
        //    full-canvas occluder. Both adjustments are documented at
        //    `WindowOccluders.occludingRects(for:among:slop:)`.
        let bounds = ribbonBounds(sections)
        let slop = configuration.strokeWidth / 2 + 1
        let drawnBounds = bounds.insetBy(dx: -slop, dy: -slop)
        let holes = WindowOccluders.occludingRects(for: drawnBounds, among: occluders, slop: slop)

        RibbonClipping.fill(
            context,
            path: path,
            holes: holes,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: oldest.rect.minX, y: oldest.rect.midY),
                endPoint: CGPoint(x: newest.rect.minX, y: newest.rect.midY)
            )
        )

        // Outline the newest position at full strength: the trail's leading edge
        // reads as the window's current footprint rather than dissolving into
        // the gradient with everything else. It is clipped identically to the
        // body — the head sits *on* the dragged window, so an unclipped outline
        // would draw a bright border across the user's window face.
        let headRect = newest.rect
        let radius = min(configuration.cornerRadius, min(headRect.width, headRect.height) / 2)
        let headPath = radius > 0 ? Path(roundedRect: headRect, cornerRadius: radius) : Path(headRect)
        RibbonClipping.stroke(
            context,
            path: headPath,
            holes: holes,
            with: .color(tint.opacity(configuration.opacity)),
            lineWidth: configuration.strokeWidth
        )

        if let glow = configuration.glow {
            // The glow is a blurred copy of the same region, so it has to lose
            // the same holes — otherwise a blur radius of a few points still
            // bleeds a soft halo across the face of the window being dragged,
            // which is the single most obvious way this effect can look broken.
            // The clip is padded by the blur radius for the same reason.
            var blurred = context
            blurred.addFilter(.blur(radius: glow.radius))
            if !holes.isEmpty,
               let clip = RibbonClipping.clipRegion(of: holes, around: path, padding: glow.radius * 3) {
                blurred.clip(to: clip, style: FillStyle(eoFill: true))
            }
            blurred.fill(
                path,
                with: .color((glow.color ?? tint).opacity(configuration.opacity * glow.intensity * 0.35))
            )
        }
    }

    /// The union of every section, used as the bounding shape for clipping.
    private func ribbonBounds(_ sections: [RibbonSection]) -> CGRect {
        sections.reduce(CGRect.null) { $0.union($1.rect) }
    }

    private func gradientStops(for sections: [RibbonSection], now: CFTimeInterval) -> [Gradient.Stop] {
        let tailFadeStart = configuration.tailFadeStart
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(sections.count)

        // Normalise positions along the ribbon so the gradient runs head to tail.
        let first = sections[0].t
        let last = sections[sections.count - 1].t
        let span = max(last - first, 0.0001)

        for section in sections {
            let position = (section.t - first) / span
            let alpha = RibbonGeometry.opacity(
                for: section,
                baseOpacity: configuration.opacity,
                fadeDuration: configuration.fadeDuration,
                tailFadeStart: tailFadeStart
            )
            stops.append(Gradient.Stop(color: trailColor(at: section, now: now).opacity(alpha),
                                      location: position))
        }

        return stops
    }

    private func leadingColor(at newest: RibbonSection, oldest: RibbonSection, now: CFTimeInterval) -> Color {
        trailColor(at: newest, now: now)
    }

    // MARK: - Color

    private func trailColor(at section: RibbonSection, now: CFTimeInterval) -> Color {
        switch configuration.strokeColor {
        case .solid(let color):
            return color
        case .gradient(let from, let to):
            return blend(from: from, to: to, amount: section.t)
        case .rainbow:
            let cycle = 3.0
            let hue = now.truncatingRemainder(dividingBy: cycle) / cycle
            return Color(hue: hue, saturation: 1.0, brightness: 1.0)
        }
    }

    private func blend(from: Color, to: Color, amount: Double) -> Color {
        guard let rgb1 = NSColor(from).usingColorSpace(.sRGB),
              let rgb2 = NSColor(to).usingColorSpace(.sRGB) else {
            return from
        }
        let f = CGFloat(max(0, min(amount, 1)))
        return Color(
            red: Double(rgb1.redComponent + (rgb2.redComponent - rgb1.redComponent) * f),
            green: Double(rgb1.greenComponent + (rgb2.greenComponent - rgb1.greenComponent) * f),
            blue: Double(rgb1.blueComponent + (rgb2.blueComponent - rgb1.blueComponent) * f)
        )
    }
}