import Foundation
import CoreGraphics
import AppKit

/// A single cross-section of the trail, carrying everything the renderer needs
/// so it never has to reach back into the sample history.
struct RibbonSection: Equatable {
    /// Rectangle at this point along the trail, in overlay-view coordinates.
    let rect: CGRect
    /// 0 at the oldest end of the ribbon, 1 at the newest (leading) end.
    let t: Double
    /// Age in seconds when the section was produced.
    let age: TimeInterval
}

/// Turns a history of window samples into the smooth outline the user actually
/// sees.
///
/// The previous renderer stamped one rectangle per recorded frame. Dragging
/// slowly produced a stack of near-identical rectangles whose alpha accumulated
/// into a grey smudge; dragging quickly left visible gaps between stamps. This
/// interpolates instead, so the ribbon is continuous regardless of how fast the
/// pointer moves.
enum RibbonGeometry {
    /// Largest distance, in points, between two consecutive ribbon sections.
    ///
    /// The old implementation left a visible dotted line whenever the pointer
    /// moved far between two 30Hz samples. Interpolating until consecutive
    /// sections are within this distance removes the gaps; the value trades
    /// smoothness against how many sections a single throw costs.
    static let interpolationSpacing: CGFloat = 8

    /// Upper bound on interpolated sections per recorded gap, so one very long
    /// throw (a window flung across a 5K display) cannot allocate unboundedly.
    static let maxSectionsPerGap = 32

    /// Builds the ribbon for one window's history.
    ///
    /// - Parameters:
    ///   - samples: oldest first. May contain a single element.
    ///   - now: current time, used to age each section.
    ///   - convert: maps a sample's Quartz-global frame into view coordinates.
    ///   - cornerRadius: requested radius, clamped per section to fit the rect.
    static func sections(
        for samples: RingBuffer<TrailSample>,
        now: CFTimeInterval,
        convert: (CGRect) -> CGRect,
        cornerRadius: CGFloat
    ) -> [RibbonSection] {
        guard !samples.isEmpty else { return [] }

        let denominator = Double(max(samples.count - 1, 1))
        var sections: [RibbonSection] = []
        sections.reserveCapacity(samples.count + min(samples.count, 16) * maxSectionsPerGap)

        append(sample: samples[0], t: 0, now: now, convert: convert, into: &sections)

        for index in 1..<max(samples.count, 1) {
            let previous = samples[index - 1]
            let sample = samples[index]

            // `movementThreshold` is expressed in POINTS, but the samples are
            // 33ms apart, so a pointer moving 3pt between samples is a continuous
            // drag, not a hole to be filled. Upsampling is therefore driven by
            // distance, not by the wall-clock gap: only a genuinely long throw
            // across the screen needs sections inserted between two samples.
            // Using the time gap here made a 30-sample slow drag emit 59
            // sections instead of 30.
            let distance = previous.frame.hypotDistance(to: sample.frame)
            let t0 = Double(index - 1) / denominator
            let t1 = Double(index) / denominator

            if distance >= interpolationSpacing {
                let steps = min(Int(distance / interpolationSpacing), maxSectionsPerGap)
                if steps > 1 {
                    for step in 1..<steps {
                        let f = Double(step) / Double(steps)
                        append(
                            at: t0 + (t1 - t0) * f,
                            age: now - (previous.timestamp + (sample.timestamp - previous.timestamp) * f),
                            rect: convert(interpolate(previous.frame, sample.frame, f)),
                            into: &sections
                        )
                    }
                }
            }

            append(sample: sample, t: t1, now: now, convert: convert, into: &sections)
        }

        return sections
    }

    private static func append(
        sample: TrailSample,
        t: Double,
        now: CFTimeInterval,
        convert: (CGRect) -> CGRect,
        into sections: inout [RibbonSection]
    ) {
        append(at: t, age: now - sample.timestamp, rect: convert(sample.frame), into: &sections)
    }

    private static func append(
        at t: Double,
        age: TimeInterval,
        rect: CGRect,
        into sections: inout [RibbonSection]
    ) {
        guard rect.width > 0, rect.height > 0 else { return }

        // A pointer that pauses mid-drag produces many identical samples. Keep
        // one per distinct position: the renderer draws the same outline
        // repeatedly otherwise, and identical alpha stacks into a bright band.
        if let last = sections.last, last.rect == rect {
            return
        }

        sections.append(RibbonSection(rect: rect, t: t, age: age))
    }

    /// Linear interpolation between two window rects. Resizing is interpolated
    /// on both edges independently, so a window dragged and resized at once
    /// produces a rect that grows from the correct corners rather than from the
    /// origin.
    static func interpolate(_ a: CGRect, _ b: CGRect, _ f: Double) -> CGRect {
        let originX = a.minX + (b.minX - a.minX) * f
        let originY = a.minY + (b.minY - a.minY) * f
        let width = a.width + (b.width - a.width) * f
        let height = a.height + (b.height - a.height) * f
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Opacity for a section.
    ///
    /// Two curves multiply: a position ramp along the ribbon so the tail fades
    /// into the head, and a time ramp so an abandoned trail dissolves even
    /// though its samples are still in the buffer. The time curve is
    /// `1 - age/fade` squared so the ribbon holds full strength briefly and then
    /// falls away instead of dimming linearly to nothing.
    static func opacity(
        for section: RibbonSection,
        baseOpacity: Double,
        fadeDuration: TimeInterval,
        tailFadeStart: Double
    ) -> Double {
        let timeFraction = fadeDuration > 0
            ? max(0, 1 - section.age / fadeDuration)
            : 1
        let positionFraction = clamp01((section.t - tailFadeStart) / max(1 - tailFadeStart, 0.0001))
        return clamp01(baseOpacity) * positionFraction * timeFraction * timeFraction
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0, min(value, 1))
    }
}