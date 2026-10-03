import Testing
import Foundation
import CoreGraphics
import SwiftUI
import AppKit
@testable import GhostTrail

/// Rasterises the renderer and reads the pixels back.
///
/// Everything else in GhostTrail is verified against values — rects, distances,
/// classifications. Those cannot catch "the path is built but nothing is painted",
/// which is the failure that matters most and the one this file exists for. A
/// `CGContext` with a `GraphicsContext` over it gives the renderer a real
/// drawing surface with no window server, no event tap and no live desktop, so
/// the assertion is about pixels that were or were not painted.
/// The clock every probe render is evaluated at.
///
/// Fixed on purpose. The ribbon's alpha ramps by sample age, so a render is a
/// function of the clock; measured across three renders of identical geometry,
/// accumulated alpha moved 5,263,122 → 5,201,486 → 5,157,020 (~0.9%) purely
/// from the renders running milliseconds apart. Pinning `now` makes renders
/// reproducible, which is what lets the occluder tests assert *exactly* rather
/// than against a tolerance.
private let probeNow: CFTimeInterval = 1_000_000

@MainActor
enum PixelProbe {
    /// Renders `trails` (cut by `occluders`) and returns the alpha channel.
    ///
    /// Only alpha is inspected: the trail's colour depends on the preset, but
    /// "was anything painted here" is purely an alpha question, and alpha is
    /// what proves a fill happened.
    ///
    /// `ImageRenderer` is the only supported way to reach a real drawing surface
    /// from a test — `GraphicsContext` has no public initialiser, so a test
    /// cannot wrap a `CGContext` itself. It renders a real SwiftUI view through
    /// the same renderer pipeline the app uses, with no window server, no event
    /// tap and no live desktop.
    static func alphaMap(
        trails: [CGWindowID: RingBuffer<TrailSample>],
        occluders: [CGRect] = [],
        configuration: GhostTrailConfiguration,
        size: CGSize = CGSize(width: 800, height: 600)
    ) throws -> (width: Int, height: Int, alpha: [UInt8]) {
        let renderer = GhostTrailRenderer(configuration: configuration)
        let view = Canvas { context, canvasSize in
            renderer.draw(
                context: context,
                trails: trails,
                occluders: occluders,
                size: canvasSize,
                converter: .identity,
                now: probeNow
            )
        }
        .frame(width: size.width, height: size.height)

        let imageRenderer = ImageRenderer(content: view)
        imageRenderer.scale = 1
        guard let cgImage = imageRenderer.cgImage else { throw ProbeError.noImage }

        var buf = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let cg = CGContext(
            data: &buf,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProbeError.noContext
        }
        cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var alpha = [UInt8](repeating: 0, count: cgImage.width * cgImage.height)
        for i in 0..<alpha.count { alpha[i] = buf[i * 4 + 3] }
        return (cgImage.width, cgImage.height, alpha)
    }

    /// Alpha at a point, in the same bottom-left coordinate space the renderer
    /// draws in.
    static func alpha(_ map: (width: Int, height: Int, alpha: [UInt8]), at point: CGPoint) -> UInt8 {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < map.width, y < map.height else { return 0 }
        return map.alpha[y * map.width + x]
    }

    static func opaqueCount(_ map: (width: Int, height: Int, alpha: [UInt8])) -> Int {
        map.alpha.reduce(into: 0) { total, value in if value > 8 { total += 1 } }
    }

    enum ProbeError: Error { case noContext, noImage }
}

/// A configuration with no glow and full opacity, so pixel counts mean what they
/// say.
///
/// `tailFadeStart = 0` matters: the alpha ramp along the ribbon runs from the
/// configured opacity down to zero at the tail, so a test cannot assume a pixel
/// is opaque just because it is painted. Measured on the 24-sample ring used by
/// these tests, alpha runs ≈67 (tail) to ≈189 (head) — a linear gradient between
/// stops, not a constant. Assertions below compare *regions* rather than
/// expecting 255.
private func probeConfiguration() -> GhostTrailConfiguration {
    var configuration = GhostTrailConfiguration()
    configuration.strokeColor = .solid(.white)
    configuration.opacity = 1
    configuration.glow = nil
    configuration.fadeDuration = 10
    configuration.tailFadeStart = 0
    configuration.frameCount = 64
    return configuration
}

/// `count` samples marching right along `y`, evenly spaced in time.
///
/// Timestamps are relative to `probeNow` so the samples' ages — and therefore
/// their alpha — are identical on every run.
private func sampleRing(count: Int, y: CGFloat = 300, width: CGFloat = 100, height: CGFloat = 80) -> RingBuffer<TrailSample> {
    var ring = RingBuffer<TrailSample>(capacity: 64)
    for i in 0..<count {
        ring.append(TrailSample(
            frame: CGRect(x: 40 + CGFloat(i) * 14, y: y, width: width, height: height),
            timestamp: probeNow - Double(count - i) * 0.02
        ))
    }
    return ring
}

/// Alpha summed over a rectangle, so a test can compare a whole area without
/// depending on any single pixel's ramp position.
///
/// Pinning `probeNow` makes renders reproducible to within ~8 units of alpha out
/// of ~5.26M (see `probeNow`). Comparison tests still carry a tolerance:
/// `ImageRenderer` is not bit-deterministic, and the tolerance must sit far
/// below what any real defect costs.
private func alphaTotal(
    _ map: (width: Int, height: Int, alpha: [UInt8]),
    in rect: CGRect
) -> Int {
    let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
    let x1 = min(map.width, Int(rect.maxX)), y1 = min(map.height, Int(rect.maxY))
    var total = 0
    for y in y0..<y1 {
        for x in x0..<x1 { total += Int(map.alpha[y * map.width + x]) }
    }
    return total
}

/// Painted area, in whole pixels of the alpha channel.
///
/// Summing raw alpha over the whole canvas conflates the ribbon with the
/// *antialiased edges of the occluder clip*: a clip boundary is a hard edge, so
/// SwiftUI lays down partial coverage along it, and a "total coverage" occluder
/// still leaves a fringe. Callers therefore count *painted* pixels — alpha above
/// a threshold — not accumulated alpha, and look at the ribbon's own rectangle
/// rather than the whole canvas.
private func paintedArea(_ map: (width: Int, height: Int, alpha: [UInt8])) -> Int {
    map.alpha.reduce(into: 0) { total, value in if value > 8 { total += 1 } }
}

@Suite("Renderer rasterisation")
@MainActor
struct RendererRasterisationTests {

    @Test("a drag actually paints pixels")
    func paintsPixels() throws {
        let map = try PixelProbe.alphaMap(
            trails: [1: sampleRing(count: 24)],
            configuration: probeConfiguration()
        )
        #expect(PixelProbe.opaqueCount(map) > 5000)
    }

    @Test("painted pixels land inside the ribbon's swept area")
    func pixelsLandInTheRibbon() throws {
        let trails = sampleRing(count: 24, y: 300, width: 100, height: 80)
        let map = try PixelProbe.alphaMap(trails: [1: trails], configuration: probeConfiguration())

        // Inside the window's own footprint: painted.
        #expect(alphaTotal(map, in: CGRect(x: 40, y: 300, width: 20, height: 80)) > 500)

        // Well below the trail (it sweeps y = 300...380): nothing.
        #expect(alphaTotal(map, in: CGRect(x: 0, y: 0, width: 800, height: 200)) == 0)

        // Well above the trail: nothing.
        #expect(alphaTotal(map, in: CGRect(x: 0, y: 500, width: 800, height: 100)) == 0)

        // And behind the head, where no sample ever reached: nothing.
        #expect(alphaTotal(map, in: CGRect(x: 500, y: 300, width: 300, height: 80)) == 0)
    }

    @Test("an occluding window erases the ribbon underneath it")
    func occluderErasesRibbon() throws {
        let trails = sampleRing(count: 24, y: 300, width: 100, height: 80)
        let configuration = probeConfiguration()

        // A window sitting squarely on the middle of the trail.
        let blocker = CGRect(x: 150, y: 250, width: 120, height: 180)

        let without = try PixelProbe.alphaMap(trails: [1: trails], configuration: configuration)
        let with = try PixelProbe.alphaMap(trails: [1: trails], occluders: [blocker],
                                           configuration: configuration)

        // The strip the blocker covers is solid ribbon without it ...
        let covered = CGRect(x: 150, y: 300, width: 120, height: 80)
        #expect(alphaTotal(without, in: covered) > 20_000)

        // ... and empty with it. Not merely dimmer: zero, because the hole is a
        // clip and a clipped region is not painted at all.
        #expect(alphaTotal(with, in: covered) == 0)

        // Ribbon before the blocker survives.
        #expect(alphaTotal(with, in: CGRect(x: 40, y: 300, width: 100, height: 80)) > 10_000)

        // Ribbon after the blocker survives.
        #expect(alphaTotal(with, in: CGRect(x: 270, y: 300, width: 110, height: 80)) > 10_000)

        // And strictly less is painted overall.
        #expect(PixelProbe.opaqueCount(with) < PixelProbe.opaqueCount(without))
    }

    @Test("an occluder that misses the ribbon changes nothing")
    func unrelatedOccluderIsIgnored() throws {
        let trails = sampleRing(count: 24, y: 300, width: 100, height: 80)
        let configuration = probeConfiguration()
        let ribbon = CGRect(x: 0, y: 250, width: 800, height: 180)

        let without = try PixelProbe.alphaMap(trails: [1: trails], configuration: configuration)
        let with = try PixelProbe.alphaMap(
            trails: [1: trails],
            occluders: [CGRect(x: 0, y: 0, width: 800, height: 100)],  // top of screen
            configuration: configuration
        )
        // Compared over the whole canvas, to catch an occluder that changes the
        // ribbon without covering it.
        //
        // `probeNow` pins the clock, which removes the 0.9%-per-render age-ramp
        // drift that made this test unwritable before. What remains is ~8 units
        // of accumulated alpha out of 5.26M (0.00015%) from `ImageRenderer`
        // resampling not being bit-deterministic. The tolerance is 1,000 —
        // ~125x that noise floor, and ~480x below the smallest genuine clipping
        // defect measured (483,860 alpha for an occluder that touched nothing).
        let whole = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(abs(alphaTotal(with, in: whole) - alphaTotal(without, in: whole)) <= 1_000)
        #expect(abs(alphaTotal(with, in: ribbon) - alphaTotal(without, in: ribbon)) <= 1_000)
    }

    @Test("an occluder covering the whole ribbon hides it entirely")
    func totalOcclusionErasesEverything() throws {
        let trails = sampleRing(count: 24, y: 300, width: 100, height: 80)
        let map = try PixelProbe.alphaMap(
            trails: [1: trails],
            occluders: [CGRect(x: 0, y: 0, width: 800, height: 600)],
            configuration: probeConfiguration()
        )
        // Nothing painted anywhere the ribbon could reach — not even an
        // antialiased fringe. See `paintedArea` for why the count is by pixel.
        #expect(paintedArea(map) == 0)
    }

    @Test("the head outline is erased too, not just the body")
    func headOutlineIsErased() throws {
        // Two near-identical samples: enough for `sections` to render, and the
        // head outline then sits on the window's own rectangle.
        var ring = RingBuffer<TrailSample>(capacity: 8)
        ring.append(TrailSample(frame: CGRect(x: 200, y: 200, width: 200, height: 200),
                                timestamp: probeNow))
        ring.append(TrailSample(frame: CGRect(x: 204, y: 200, width: 200, height: 200),
                                timestamp: probeNow))

        var configuration = probeConfiguration()
        configuration.cornerRadius = 0
        configuration.strokeWidth = 6

        let withHead = try PixelProbe.alphaMap(trails: [1: ring], configuration: configuration)
        #expect(paintedArea(withHead) > 0)

        // Cover the head's rect entirely: even the outline must go.
        let erased = try PixelProbe.alphaMap(
            trails: [1: ring],
            occluders: [CGRect(x: 150, y: 150, width: 320, height: 320)],
            configuration: configuration
        )
        #expect(paintedArea(erased) == 0)
    }

    @Test("a single-sample trail is not drawn")
    func singleSampleIsNotDrawn() throws {
        var ring = RingBuffer<TrailSample>(capacity: 8)
        ring.append(TrailSample(frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                timestamp: probeNow))
        let map = try PixelProbe.alphaMap(trails: [1: ring], configuration: probeConfiguration())
        #expect(PixelProbe.opaqueCount(map) == 0)
    }

    @Test("every shipped preset paints something")
    func presetsPaint() throws {
        let presets: [(String, GhostTrailConfiguration)] = [
            ("subtle", .subtle), ("dramatic", .dramatic), ("retro", .retro),
            ("neon", .neon), ("glass", .glass)
        ]
        for (name, preset) in presets {
            var configuration = preset
            configuration.glow = nil
            configuration.fadeDuration = 10
            let map = try PixelProbe.alphaMap(trails: [1: sampleRing(count: 24)],
                                               configuration: configuration)
            #expect(PixelProbe.opaqueCount(map) > 2000, "\(name) painted nothing")
        }
    }
}

@Suite("Occluder geometry")
struct WindowOccluderTests {

    @Test("only normal and floating layers occlude")
    func layerFilter() {
        // The filter itself is a private set; this pins the two levels it names
        // so a future change to either is deliberate.
        #expect(CGWindowLevelForKey(.normalWindow) == 0)
        #expect(CGWindowLevelForKey(.floatingWindow) == 3)
        // Panels sit above floating and must NOT erase the ribbon: punching a
        // hole for a menu or a tooltip looks like a bug, not depth.
        #expect(CGWindowLevelForKey(.modalPanelWindow) > CGWindowLevelForKey(.floatingWindow))
    }

    @Test("intersections drop windows that miss the ribbon")
    func intersectionsOnly() {
        let ribbon = CGRect(x: 0, y: 0, width: 100, height: 100)
        let hits = WindowOccluders.occludingRects(
            for: ribbon,
            among: [CGRect(x: 50, y: 50, width: 100, height: 100),   // overlaps
                    CGRect(x: 500, y: 500, width: 10, height: 10)]  // misses
        )
        #expect(hits.count == 1)
        #expect(hits[0] == CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test("no windows means no holes")
    func noWindowsNoHoles() {
        #expect(WindowOccluders.occludingRects(for: CGRect(x: 0, y: 0, width: 10, height: 10), among: []).isEmpty)
    }

    @Test("a window fully containing the ribbon collapses to the ribbon")
    func coveringWindow() {
        let ribbon = CGRect(x: 10, y: 10, width: 20, height: 20)
        let holes = WindowOccluders.occludingRects(
            for: ribbon,
            among: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
        )
        #expect(holes == [ribbon])
    }
}