import Foundation
import Testing
import SwiftUI
@testable import CursorTrail

/// Configuration defaults, clamping, and the derived diminishing widths the renderer
/// relies on.
@Suite("TrailConfiguration")
struct TrailConfigurationTests {

    @Test("defaults match the documented values")
    func defaultConfiguration() {
        let config = TrailConfiguration()

        #expect(config.thickness == 12.0)
        #expect(config.length == 10)
        #expect(config.style == .ribbon)
        #expect(config.opacity == 0.8)
        #expect(config.speedMode == .adaptive)
        if case .rainbow = config.color {
            // default colour is .rainbow
        } else {
            Issue.record("default color must be .rainbow")
        }
        #expect(config.glow == nil)
    }

    @Test("explicit values are preserved")
    func customConfiguration() {
        let config = TrailConfiguration(
            color: .gradient(.red, .blue),
            thickness: 6,
            length: 200,
            style: .ribbon,
            opacity: 0.5,
            glow: GlowConfig(radius: 10, intensity: 0.6)
        )

        #expect(config.thickness == 6)
        #expect(config.length == 200)
        #expect(config.style == .ribbon)
        #expect(config.opacity == 0.5)
        #expect(config.glow != nil)
    }

    @Test("out-of-range values are clamped into valid bounds")
    func clamping() {
        let config = TrailConfiguration(
            thickness: -50,
            length: 3,
            fadeSpeed: 0,
            rainbowSpeed: -1,
            diminishingIntensity: 9,
            opacity: 4
        )

        #expect(config.thickness == 1, "thickness must never go below 1pt")
        #expect(config.length == 10, "length must never go below 10 points")
        #expect(config.fadeSpeed == 0.1)
        #expect(config.rainbowSpeed == 0.1)
        #expect(config.diminishingIntensity == 1.0)
        #expect(config.opacity == 1.0)

        let negative = TrailConfiguration(diminishingIntensity: -1, opacity: -1)
        #expect(negative.opacity == 0)
        #expect(negative.diminishingIntensity == 0)
    }

    @Test("diminishing off keeps full ribbon width and a thin line minimum")
    func diminishingDisabled() {
        let config = TrailConfiguration(diminishing: false)

        #expect(config.diminishingMin(forLine: false) == 1.0, "a ribbon with no diminishing stays full width")
        #expect(config.diminishingMin(forLine: true) == 0.2)
    }

    @Test("diminishing intensity scales the minimum width down")
    func diminishingEnabled() {
        let strong = TrailConfiguration(diminishing: true, diminishingIntensity: 0.7)
        let weak = TrailConfiguration(diminishing: true, diminishingIntensity: 0.0)

        #expect(abs(strong.diminishingMin(forLine: false) - 0.3) < 1e-9)
        #expect(abs(strong.diminishingMin(forLine: true) - 0.06) < 1e-9)
        #expect(abs(weak.diminishingMin(forLine: false) - 1.0) < 1e-9)
        #expect(abs(weak.diminishingMin(forLine: true) - 0.2) < 1e-9)
    }

    @Test("minimum widths stay within the 0...1 range used as a width fraction")
    func diminishingStaysNormalized() {
        for intensity in stride(from: 0.0, through: 1.0, by: 0.05) {
            let config = TrailConfiguration(diminishing: true, diminishingIntensity: intensity)
            for line in [true, false] {
                let minimum = config.diminishingMin(forLine: line)
                #expect(minimum >= 0)
                #expect(minimum <= 1)
            }
        }
    }

    @Test("glow intensity is clamped to a usable range")
    func glowClamping() {
        #expect(GlowConfig(radius: 4, intensity: 5).intensity <= 1)
        #expect(GlowConfig(radius: 4, intensity: -5).intensity >= 0)
    }
}