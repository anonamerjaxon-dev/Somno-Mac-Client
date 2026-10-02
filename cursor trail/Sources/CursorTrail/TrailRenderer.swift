import SwiftUI
import AppKit

public final class TrailRenderer {
    private let configuration: TrailConfiguration

    /// Points are drawn this far below the reported cursor position to sit the trail
    /// under the cursor arrow. Internal for tests.
    static let yOffset: CGFloat = 16

    /// Samples generated per spline segment when resampling. Internal for tests.
    static let samplesPerSegment: Int = 8

    public init(configuration: TrailConfiguration) {
        self.configuration = configuration
    }

    public func draw(context: GraphicsContext, points: RingBuffer<TrailPoint>) {
        guard Self.isDrawable(pointCount: points.count) else { return }

        let now = CACurrentMediaTime()
        let opacity = configuration.opacity

        switch configuration.style {
        case .line:
            drawLine(context: context, points: points, now: now, opacity: opacity)
        case .ribbon:
            drawRibbon(context: context, points: points, now: now, opacity: opacity)
        }

        if let glow = configuration.glow {
            drawGlow(context: context, points: points, glow: glow, now: now, opacity: opacity)
        }
    }

    // MARK: - Line

    private func drawLine(context: GraphicsContext, points: RingBuffer<TrailPoint>, now: CFTimeInterval, opacity: Double) {
        let count = points.count
        let path = polylinePath(from: points)
        let color = trailColor(at: count / 2, total: count, now: now)
        let thickness = lineThickness(at: count / 2, total: count)
        let minWidth = configuration.diminishingMin(forLine: true)

        for pass in 0..<4 {
            let progress = CGFloat(pass) / 3
            let width = max(thickness * (minWidth + progress * (1 - minWidth)), 0.5)
            let alpha = (0.15 + progress * 0.85) * opacity

            context.stroke(
                path,
                with: .color(color.opacity(alpha)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: - Ribbon

    private func drawRibbon(context: GraphicsContext, points: RingBuffer<TrailPoint>, now: CFTimeInterval, opacity: Double) {
        guard !Self.usesRibbonFallback(pointCount: points.count) else {
            drawLine(context: context, points: points, now: now, opacity: opacity)
            return
        }

        let count = points.count
        let baseWidth = configuration.thickness * 2
        let minWidth = configuration.diminishingMin(forLine: false)
        let smoothPoints = resampleCurve(points: points)
        let smoothCount = smoothPoints.count

        var leftEdge = [CGPoint]()
        var rightEdge = [CGPoint]()
        leftEdge.reserveCapacity(smoothCount)
        rightEdge.reserveCapacity(smoothCount)

        for i in 0..<smoothCount {
            let progress = CGFloat(i) / CGFloat(max(smoothCount - 1, 1))
            let halfWidth = (baseWidth / 2) * (minWidth + progress * (1 - minWidth))

            let prev = smoothPoints[max(i - 1, 0)]
            let next = smoothPoints[min(i + 1, smoothCount - 1)]
            let dx = next.x - prev.x
            let dy = next.y - prev.y
            let length = sqrt(dx * dx + dy * dy)
            let nx = length > 0 ? -dy / length : 0
            let ny = length > 0 ?  dx / length : 1

            let pos = smoothPoints[i]
            leftEdge.append(CGPoint(x: pos.x + nx * halfWidth, y: pos.y + ny * halfWidth))
            rightEdge.append(CGPoint(x: pos.x - nx * halfWidth, y: pos.y - ny * halfWidth))
        }

        var path = Path()
        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() {
            path.addLine(to: point)
        }
        for point in rightEdge.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        let color = trailColor(at: count / 2, total: count, now: now)
        context.fill(path, with: .color(color.opacity(opacity)))
    }

    // MARK: - Glow

    private func drawGlow(context: GraphicsContext, points: RingBuffer<TrailPoint>, glow: GlowConfig, now: CFTimeInterval, opacity: Double) {
        let path = polylinePath(from: points)
        let baseColor = trailColor(at: 0, total: points.count, now: now)
        let glowColor = (glow.color ?? baseColor).opacity(glow.intensity * 0.3 * opacity)

        var blurred = context
        blurred.addFilter(.blur(radius: glow.radius))
        blurred.stroke(
            path,
            with: .color(glowColor),
            style: StrokeStyle(lineWidth: configuration.thickness + glow.radius, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Geometry

    /// Below this many points there is no segment to stroke. Pure, so the guard can be
    /// tested without a `GraphicsContext`.
    static func isDrawable(pointCount: Int) -> Bool {
        pointCount >= 2
    }

    /// A ribbon needs at least three points to build a filled shape; with fewer it
    /// degrades to the stroked line path.
    static func usesRibbonFallback(pointCount: Int) -> Bool {
        pointCount < 3
    }

    /// Number of samples produced when resampling `pointCount` points through the
    /// Catmull-Rom spline. Guards against a zero/negative count producing garbage.
    static func resampleSampleCount(pointCount: Int) -> Int {
        guard pointCount > 0 else { return 0 }
        return (pointCount - 1) * samplesPerSegment + 1
    }

    private func polylinePath(from points: RingBuffer<TrailPoint>) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.position.x, y: first.position.y + Self.yOffset))
        for i in 1..<points.count {
            let p = points[i].position
            path.addLine(to: CGPoint(x: p.x, y: p.y + Self.yOffset))
        }
        return path
    }

    private func resampleCurve(points: RingBuffer<TrailPoint>) -> [CGPoint] {
        let count = points.count
        let samplesPerSegment = Self.samplesPerSegment
        let totalSamples = Self.resampleSampleCount(pointCount: count)
        guard totalSamples > 0 else { return [] }
        var result = [CGPoint]()
        result.reserveCapacity(totalSamples)

        for i in 0..<totalSamples {
            let t = CGFloat(i) / CGFloat(samplesPerSegment)
            let segment = Int(t)
            let fraction = t - CGFloat(segment)

            let p0 = points[max(segment - 1, 0)].position
            let p1 = points[segment].position
            let p2 = points[min(segment + 1, count - 1)].position
            let p3 = points[min(segment + 2, count - 1)].position

            let pt = Self.catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: fraction)
            result.append(CGPoint(x: pt.x, y: pt.y + Self.yOffset))
        }

        return result
    }

    private static func catmullRom(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    // MARK: - Color

    private func trailColor(at index: Int, total: Int, now: CFTimeInterval) -> Color {
        switch configuration.color {
        case .solid(let color):
            return color
        case .gradient(let from, let to):
            let amount = Double(index) / Double(max(total - 1, 1))
            return blend(from: from, to: to, amount: amount)
        case .rainbow:
            let cycle = 3.0 / configuration.rainbowSpeed
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

    private func lineThickness(at index: Int, total: Int) -> CGFloat {
        let progress = CGFloat(index) / CGFloat(max(total - 1, 1))
        return configuration.thickness * (1.0 - progress * 0.5)
    }
}