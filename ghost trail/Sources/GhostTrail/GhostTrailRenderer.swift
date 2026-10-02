import AppKit
import SwiftUI

final class GhostTrailRenderer {
    private let configuration: GhostTrailConfiguration

    init(configuration: GhostTrailConfiguration) {
        self.configuration = configuration
    }

    func draw(context: GraphicsContext, trails: [CGWindowID: RingBuffer<TrailFrame>], size: CGSize, converter: TrailCoordinateConverter = .identity) {
        let now = CACurrentMediaTime()
        let baseOpacity = configuration.opacity

        for (_, trail) in trails {
            drawTrail(context: context, trail: trail, now: now, baseOpacity: baseOpacity, size: size, converter: converter)
        }
    }

    private func drawTrail(context: GraphicsContext, trail: RingBuffer<TrailFrame>, now: CFTimeInterval, baseOpacity: Double, size: CGSize, converter: TrailCoordinateConverter) {
        let count = trail.count
        guard count > 0 else { return }

        let radius = configuration.cornerRadius

        if configuration.style == .solid {
            drawSolidTrail(context: context, trail: trail, now: now, baseOpacity: baseOpacity, size: size, radius: radius, count: count, converter: converter)
            return
        }

        for i in (0..<count).reversed() {
            let frame = trail[i]
            let age = now - frame.timestamp
            let opacity = timeBasedOpacity(age: age, baseOpacity: baseOpacity)

            guard opacity > 0.01 else { continue }

            let color = trailColor(at: i, total: count, now: now)
            let rect = converter.viewRect(fromQuartz: frame.frame)

            guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
            guard rect.size.width > 0 && rect.size.height > 0 else { continue }

            let effectiveRadius = min(radius, min(rect.width, rect.height) / 2)

            switch configuration.style {
            case .outline:
                let path = Path(roundedRect: rect, cornerRadius: effectiveRadius)
                context.stroke(
                    path,
                    with: .color(color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: configuration.strokeWidth)
                )

            case .filled:
                let path = Path(roundedRect: rect, cornerRadius: effectiveRadius)
                // `.filled` adds a translucent interior under the outline. It must be
                // derived from `color` alone — applying the faded `color.opacity(opacity)`
                // and then another `opacity * 0.3` squared the alpha and made faint,
                // old frames vanish while fresh ones looked correct.
                context.fill(path, with: .color(color.opacity(opacity * 0.3)))
                context.stroke(
                    path,
                    with: .color(color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: configuration.strokeWidth)
                )

            case .solid:
                break
            }
        }

        if let glow = configuration.glow {
            drawGlow(context: context, trail: trail, now: now, baseOpacity: baseOpacity, glow: glow, converter: converter)
        }
    }

    private func drawSolidTrail(context: GraphicsContext, trail: RingBuffer<TrailFrame>, now: CFTimeInterval, baseOpacity: Double, size: CGSize, radius: CGFloat, count: Int, converter: TrailCoordinateConverter) {
        let hue = trailColor(at: count - 1, total: count, now: now)

        // Each layer stacks N nested window outlines, so its per-layer alpha must be
        // scaled by `baseOpacity` — otherwise `GhostTrail.opacity` was ignored
        // entirely by the `.solid` style.
        let layers: [(fraction: Double, alpha: Double)] = [
            (1.0,  0.06),
            (0.65, 0.12),
            (0.35, 0.20),
            (0.15, 0.30),
        ]

        for (fraction, layerAlpha) in layers {
            let maxIndex = min(count - 1, Int(Double(count) * fraction))
            guard maxIndex >= 0 else { continue }
            let layerOpacity = baseOpacity * layerAlpha

            var path = Path()
            var added = false

            for i in (0...maxIndex).reversed() {
                let frame = trail[i]
                let age = now - frame.timestamp
                guard timeBasedOpacity(age: age, baseOpacity: baseOpacity) > 0.01 else { continue }
                let rect = converter.viewRect(fromQuartz: frame.frame)
                guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                guard rect.size.width > 0, rect.size.height > 0 else { continue }
                let effectiveRadius = min(radius, min(rect.width, rect.height) / 2)
                path.addPath(Path(roundedRect: rect, cornerRadius: effectiveRadius))
                added = true
            }

            if added {
                context.fill(path, with: .color(hue.opacity(layerOpacity)))
            }
        }

        if let glow = configuration.glow {
            var allPath = Path()
            for i in (0..<count).reversed() {
                let frame = trail[i]
                let age = now - frame.timestamp
                guard timeBasedOpacity(age: age, baseOpacity: baseOpacity) > 0.01 else { continue }
                let rect = converter.viewRect(fromQuartz: frame.frame)
                guard rect.size.width > 0, rect.size.height > 0 else { continue }
                let effectiveRadius = min(radius, min(rect.width, rect.height) / 2)
                allPath.addPath(Path(roundedRect: rect, cornerRadius: effectiveRadius))
            }
            var blurred = context
            blurred.addFilter(.blur(radius: glow.radius))
            blurred.stroke(
                allPath,
                with: .color((glow.color ?? hue).opacity(baseOpacity * glow.intensity * 0.25)),
                style: StrokeStyle(lineWidth: glow.radius + 1)
            )
        }
    }

    private func drawGlow(context: GraphicsContext, trail: RingBuffer<TrailFrame>, now: CFTimeInterval, baseOpacity: Double, glow: GlowConfig, converter: TrailCoordinateConverter) {
        let count = trail.count
        guard count > 0 else { return }
        let radius = configuration.cornerRadius

        var blurred = context
        blurred.addFilter(.blur(radius: glow.radius))

        for i in (0..<count).reversed() {
            let frame = trail[i]
            let age = now - frame.timestamp
            let opacity = timeBasedOpacity(age: age, baseOpacity: baseOpacity) * glow.intensity * 0.3

            guard opacity > 0.01 else { continue }

            let glowColor = (glow.color ?? trailColor(at: i, total: count, now: now)).opacity(opacity)
            let rect = converter.viewRect(fromQuartz: frame.frame)

            let effectiveRadius = min(radius, min(rect.width, rect.height) / 2)
            let path = effectiveRadius > 0
                ? Path(roundedRect: rect, cornerRadius: effectiveRadius)
                : Path(rect)

            blurred.stroke(
                path,
                with: .color(glowColor),
                style: StrokeStyle(lineWidth: configuration.strokeWidth + glow.radius)
            )
        }
    }

    private func timeBasedOpacity(age: CFTimeInterval, baseOpacity: Double) -> Double {
        let fadeDuration = configuration.fadeDuration
        guard fadeDuration > 0 else { return baseOpacity }
        let fraction = max(0, 1.0 - age / fadeDuration)
        return baseOpacity * fraction
    }

    private func trailColor(at index: Int, total: Int, now: CFTimeInterval) -> Color {
        switch configuration.strokeColor {
        case .solid(let color):
            return color
        case .gradient(let from, let to):
            let amount = Double(index) / Double(max(total - 1, 1))
            return blend(from: from, to: to, amount: amount)
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
        let r = Double(rgb1.redComponent + (rgb2.redComponent - rgb1.redComponent) * CGFloat(amount))
        let g = Double(rgb1.greenComponent + (rgb2.greenComponent - rgb1.greenComponent) * CGFloat(amount))
        let b = Double(rgb1.blueComponent + (rgb2.blueComponent - rgb1.blueComponent) * CGFloat(amount))
        return Color(red: r, green: g, blue: b)
    }
}