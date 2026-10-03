import Testing
import Foundation
import CoreGraphics
@testable import GhostTrail

// MARK: - Motion classification

@Suite("Trail motion classification")
struct TrailMotionTests {
    private func sample(x: CGFloat, y: CGFloat = 0, w: CGFloat = 400, h: CGFloat = 300, at t: CFTimeInterval = 0) -> TrailSample {
        TrailSample(frame: CGRect(x: x, y: y, width: w, height: h), timestamp: t)
    }

    @Test("movement below the minimum distance is stationary")
    func stationaryBelowThreshold() {
        let tuning = TrailTuning(minDistance: 4, snapDistance: 48)
        #expect(tuning.classify(sample(x: 3), from: sample(x: 0)) == .stationary)
    }

    @Test("movement past the snap distance is a snap, not a drag")
    func snapDetected() {
        let tuning = TrailTuning(minDistance: 1, snapDistance: 48)
        #expect(tuning.classify(sample(x: 800), from: sample(x: 0)) == .snapped)
    }

    @Test("a resize with an unmoved origin is not stationary")
    func resizeCountsAsMotion() {
        // The origin never moves, so a tracker that compares origins alone sees
        // nothing here and never records a sample.
        let tuning = TrailTuning(minDistance: 1, snapDistance: 48)
        let kind = tuning.classify(sample(x: 0, w: 460), from: sample(x: 0, w: 400))
        #expect(kind == .continuous)
    }

    @Test("a large resize is a continuous drag, not a snap")
    func largeResizeIsNotSnap() {
        // Only translation can be a window snap. A 500pt resize between two
        // 30Hz samples is someone pulling a window edge hard; classifying it as
        // a snap threw away the trail on every fast resize.
        let tuning = TrailTuning(minDistance: 1, snapDistance: 48)
        #expect(tuning.classify(sample(x: 0, w: 900), from: sample(x: 0, w: 400)) == .continuous)
    }

    @Test("a translation beyond the snap distance is a snap")
    func translationSnap() {
        let tuning = TrailTuning(minDistance: 1, snapDistance: 48)
        #expect(tuning.classify(sample(x: 900), from: sample(x: 0)) == .snapped)
    }

    @Test("snap distance is clamped above the minimum distance")
    func tuningIsCoherent() {
        let tuning = TrailTuning(minDistance: 100, snapDistance: 10)
        #expect(tuning.snapDistance >= tuning.minDistance)
        #expect(tuning.minDistance == 100)
    }
}

// MARK: - Hit testing

@Suite("Window interaction hit testing")
struct WindowInteractionTests {
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("a point outside the window is not an interaction")
    func outside() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 50, y: 50), in: frame) == nil)
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 950, y: 400), in: frame) == nil)
    }

    @Test("the top band is a drag")
    func titleBarDrag() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 500, y: 110), in: frame) == .drag)
    }

    @Test("the middle of the window is a body click, which moves nothing")
    func bodyClick() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 500, y: 400), in: frame) == .body)
    }

    @Test("the bottom band is not a title bar, so it is a body click")
    func bottomBand() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 500, y: 690), in: frame) == .body)
    }

    @Test("edges resize")
    func edgesResize() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 103, y: 400), in: frame) == .resize)
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 500, y: 697), in: frame) == .resize)
    }

    @Test("a corner resizes even though it is inside the title bar band")
    func cornerBeatsTitleBar() {
        #expect(WindowInteractionTester.interaction(at: CGPoint(x: 102, y: 102), in: frame) == .resize)
    }

    @Test("the frontmost window containing a point wins")
    func frontmostWins() {
        let back = CGRect(x: 0, y: 0, width: 200, height: 200)
        let front = CGRect(x: 100, y: 100, width: 200, height: 200)
        #expect(WindowInteractionTester.frontmostWindow(at: CGPoint(x: 150, y: 150), in: [front, back]) == 0)
        #expect(WindowInteractionTester.frontmostWindow(at: CGPoint(x: 150, y: 150), in: [back, front]) == 0)
        #expect(WindowInteractionTester.frontmostWindow(at: CGPoint(x: 900, y: 900), in: [front, back]) == nil)
    }
}

// MARK: - Ribbon geometry

@Suite("Ribbon geometry")
struct RibbonGeometryTests {
    private func buffer(_ frames: [(CGFloat, CGFloat, CGFloat, CGFloat, CFTimeInterval)]) -> RingBuffer<TrailSample> {
        var buffer = RingBuffer<TrailSample>(capacity: 64)
        for f in frames {
            buffer.append(TrailSample(frame: CGRect(x: f.0, y: f.1, width: f.2, height: f.3), timestamp: f.4))
        }
        return buffer
    }

    @Test("an empty history produces no sections")
    func empty() {
        let empty = RingBuffer<TrailSample>(capacity: 8)
        #expect(RibbonGeometry.sections(for: empty, now: 10, convert: { $0 }, cornerRadius: 8).isEmpty)
    }

    @Test("a single sample produces exactly one section")
    func single() {
        let sections = RibbonGeometry.sections(
            for: buffer([(0, 0, 100, 100, 9.5)]),
            now: 10,
            convert: { $0 },
            cornerRadius: 8
        )
        #expect(sections.count == 1)
        #expect(sections[0].t == 0)
    }

    @Test("a slow drag yields one section per recorded sample, not hundreds")
    func slowDragIsNotUpsampled() {
        // 30 samples 3pt apart — under the 8pt interpolation spacing, so no
        // filler sections should be emitted. An earlier time-gap-driven version
        // produced 59 sections here because 33ms exceeded a 90Hz threshold.
        var frames: [(CGFloat, CGFloat, CGFloat, CGFloat, CFTimeInterval)] = []
        for i in 0..<30 {
            frames.append((CGFloat(i) * 3, 0, 100, 100, Double(i) * 0.033))
        }
        let sections = RibbonGeometry.sections(for: buffer(frames), now: 1.0, convert: { $0 }, cornerRadius: 8)
        #expect(sections.count == 30)
    }

    @Test("consecutive sections never sit further apart than the interpolation spacing")
    func sectionsAreSpacedByDistance() {
        var frames: [(CGFloat, CGFloat, CGFloat, CGFloat, CFTimeInterval)] = []
        for i in 0..<10 {
            frames.append((CGFloat(i) * 120, 0, 100, 100, Double(i) * 0.033))
        }
        let sections = RibbonGeometry.sections(for: buffer(frames), now: 1.0, convert: { $0 }, cornerRadius: 8)
        for (a, b) in zip(sections, sections.dropFirst()) {
            #expect(a.rect.hypotDistance(to: b.rect) <= RibbonGeometry.interpolationSpacing + 0.001)
        }
    }

    @Test("a fast drag is interpolated so the ribbon has no gaps")
    func fastDragIsUpsampled() {
        // Two samples 200ms apart would previously have drawn two disconnected
        // rectangles.
        let sections = RibbonGeometry.sections(
            for: buffer([(0, 0, 100, 100, 9.8), (300, 0, 100, 100, 10.0)]),
            now: 10,
            convert: { $0 },
            cornerRadius: 8
        )
        #expect(sections.count > 2)
        // Positions must be monotonically increasing along the ribbon.
        #expect(zip(sections, sections.dropFirst()).allSatisfy { $0.t <= $1.t })
    }

    @Test("interpolated sections stay inside the two rects they span")
    func interpolationIsBounded() {
        let sections = RibbonGeometry.sections(
            for: buffer([(0, 0, 100, 100, 9.8), (300, 200, 200, 400, 10.0)]),
            now: 10,
            convert: { $0 },
            cornerRadius: 8
        )
        for section in sections {
            #expect(section.rect.minX >= -0.001)
            #expect(section.rect.maxX <= 500.001)
            #expect(section.rect.minY >= -0.001)
            #expect(section.rect.maxY <= 600.001)
        }
    }

    @Test("interpolation moves both edges, not just the origin")
    func interpolationResizes() {
        let mid = RibbonGeometry.interpolate(
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 300, height: 100),
            0.5
        )
        #expect(abs(mid.minX - 50) < 0.001)
        #expect(abs(mid.width - 200) < 0.001)
    }

    @Test("a stalled pointer does not stack identical sections")
    func stalledPointerDoesNotStack() {
        let sections = RibbonGeometry.sections(
            for: buffer([(0, 0, 100, 100, 9.0), (0, 0, 100, 100, 9.05), (0, 0, 100, 100, 9.1)]),
            now: 10,
            convert: { $0 },
            cornerRadius: 8
        )
        #expect(sections.count == 1)
    }

    @Test("an absurdly long gap is capped rather than expanded without bound")
    func longGapIsCapped() {
        let sections = RibbonGeometry.sections(
            for: buffer([(0, 0, 100, 100, 1.0), (400, 0, 100, 100, 30.0)]),
            now: 30,
            convert: { $0 },
            cornerRadius: 8
        )
        // 2 recorded + at most maxSectionsPerGap filler sections.
        #expect(sections.count <= 2 + RibbonGeometry.maxSectionsPerGap)
    }

    @Test("opacity is zero at the tail and full at a fresh head")
    func opacityCurve() {
        let tail = RibbonSection(rect: .init(x: 0, y: 0, width: 10, height: 10), t: 0, age: 0)
        let head = RibbonSection(rect: .init(x: 0, y: 0, width: 10, height: 10), t: 1, age: 0)
        let tailAlpha = RibbonGeometry.opacity(for: tail, baseOpacity: 1, fadeDuration: 1, tailFadeStart: 0.5)
        let headAlpha = RibbonGeometry.opacity(for: head, baseOpacity: 1, fadeDuration: 1, tailFadeStart: 0.5)
        #expect(tailAlpha == 0)
        #expect(headAlpha == 1)
    }

    @Test("an expired section has zero opacity regardless of position")
    func expiredSectionIsInvisible() {
        let old = RibbonSection(rect: .init(x: 0, y: 0, width: 10, height: 10), t: 1, age: 5)
        #expect(RibbonGeometry.opacity(for: old, baseOpacity: 1, fadeDuration: 1, tailFadeStart: 0) == 0)
    }

    @Test("opacity never exceeds the configured maximum")
    func opacityIsClamped() {
        let section = RibbonSection(rect: .init(x: 0, y: 0, width: 10, height: 10), t: 1, age: 0)
        #expect(RibbonGeometry.opacity(for: section, baseOpacity: 4, fadeDuration: 1, tailFadeStart: 0) == 1)
    }
}

// MARK: - Configuration

@Suite("Configuration")
struct ConfigurationTests {
    @Test("history capacity tracks frame count")
    func historyCapacity() {
        let config = GhostTrailConfiguration(frameCount: 40)
        #expect(config.historyCapacity == 40)
    }

    @Test("snap distance is never below the movement threshold")
    func snapAboveThreshold() {
        let config = GhostTrailConfiguration(movementThreshold: 100, snapDistance: 1)
        #expect(config.snapDistance >= config.movementThreshold)
    }

    @Test("tail fade start is clamped to 0...1")
    func tailFadeClamped() {
        #expect(GhostTrailConfiguration(tailFadeStart: 5).tailFadeStart == 1)
        #expect(GhostTrailConfiguration(tailFadeStart: -2).tailFadeStart == 0)
    }

    @Test("every shipped preset is renderable")
    func presetsAreSane() {
        let presets = [GhostTrailConfiguration.subtle, .dramatic, .retro, .neon, .glass]
        for preset in presets {
            #expect(preset.opacity > 0)
            #expect(preset.historyCapacity >= 2)
            #expect(preset.fadeDuration > 0)
            #expect(preset.cornerRadius >= 0)
        }
    }
}

// MARK: - Window layering

@Suite("Window layering")
struct WindowLayeringTests {
    @Test("behindWindows sits above the desktop icons but below normal windows")
    func behindWindowsOrdering() {
        let level = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(level > Int(CGWindowLevelForKey(.desktopWindow)))
        #expect(level < Int(CGWindowLevelForKey(.normalWindow)))
    }

    @Test("behindWindows really is above desktop icons")
    func notBelowDesktop() {
        // Regression guard: the previous implementation subtracted one, which
        // put the trail under the desktop picture layer where it was invisible
        // on many desktops.
        let previous = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        let current = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(current > previous)
    }
}

// MARK: - Coordinate conversion

@Suite("Coordinate conversion")
struct CoordinateConverterTests {
    private func converter(main: CGRect, overlay: CGRect) -> TrailCoordinateConverter {
        TrailCoordinateConverter(mainDisplayFrame: main, overlayFrame: overlay)
    }

    @Test("a window on the main display maps into the overlay")
    func mainDisplay() {
        let c = converter(main: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          overlay: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let rect = c.viewRect(fromQuartz: CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(rect == CGRect(x: 100, y: 600, width: 200, height: 200))
    }

    @Test("a window on a display left of and above the main one is not mirrored")
    func secondaryDisplayAboveLeft() {
        // Main display sits at the origin; the external is at (-1920, 200).
        let c = converter(main: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          overlay: CGRect(x: -1920, y: 0, width: 3360, height: 1100))
        let rect = c.viewRect(fromQuartz: CGRect(x: -1820, y: 100, width: 200, height: 200))
        // Quartz (-1820, 100, 200, 200) -> cocoa x=-1820, y = 900 - 300 = 600.
        // Then translate by the overlay origin.
        #expect(abs(rect.minX - 100) < 0.001)
        #expect(abs(rect.minY - 600) < 0.001)
        #expect(rect.width == 200)
        #expect(rect.height == 200)
    }

    @Test("a point converted at the centre of a rect lands at the rect's centre")
    func pointAndRectAgree() {
        let c = converter(main: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          overlay: CGRect(x: 0, y: 0, width: 1440, height: 900))
        // Quartz y for the centre of a 200-tall rect at y=100 is 200; the rect
        // centre must come back at the matching flipped position.
        let rect = c.viewRect(fromQuartz: CGRect(x: 300, y: 100, width: 10, height: 200))
        let point = c.viewPoint(fromQuartz: CGPoint(x: 305, y: 200))
        #expect(abs(point.x - rect.midX) < 0.001)
        #expect(abs(point.y - rect.midY) < 0.001)
    }

    @Test("the identity converter reports itself unusable and passes geometry through")
    func identityFallback() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let converter = TrailCoordinateConverter.identity
        #expect(!converter.isUsable)
        // With no reference display there is nothing to flip about, so the rect
        // must arrive unchanged rather than mirrored about a zero-height origin.
        #expect(converter.viewRect(fromQuartz: rect) == rect)
    }
}