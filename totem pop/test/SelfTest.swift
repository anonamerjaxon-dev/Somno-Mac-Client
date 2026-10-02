import Foundation

/// Self-test harness for the parts of the motion-sensor app that do not need
/// hardware.
///
/// Everything exercised here is deliberately pure:
/// - `MotionSensorManager.parseXYZ(from:)` — the HID report parser
/// - `AxisBarGeometry` — the value-bar anchoring math from `ContentView.swift`
///
/// The app binary (`MotionSensor`) is a SwiftUI app and cannot be linked into a
/// command-line test. To keep both in sync, the geometry type lives in its own
/// file (`AxisBarGeometry.swift`) which is compiled into BOTH the app and this
/// test. The parser lives in `MotionSensorManager.swift`; that file pulls in
/// IOKit and `ObservableObject`, so rather than duplicating the parser we
/// compile the real manager into the test binary. It links cleanly without ever
/// opening a device — `start()` is simply never called.
///
/// Run:  ./build/MotionSensorSelfTest   → exit 0 on success, 1 on any failure.
enum SelfTest {

    static func run() -> Int {
        var failures = 0

        print("🧪 MotionSensor self-test")
        print("=========================")
        print("")

        failures += testParseKnownReport()
        failures += testParseOffsetRegression()
        failures += testParseRejectsShortReport()
        failures += testParseScaling()
        failures += testReportGeometry()
        failures += testBarAnchoring()
        failures += testBarClamping()

        print("")
        if failures == 0 {
            print("✅ All self-tests passed.")
            return 0
        }
        print("❌ \(failures) self-test assertion(s) FAILED.")
        return 1
    }

    // MARK: - Assertion helpers

    private static var currentTest = ""

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("   ✓ \(message)")
        } else {
            print("   ✗ \(message)")
            currentTestHadFailure = true
        }
    }

    private static var currentTestHadFailure = false

    private static func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-5) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func begin(_ name: String) {
        currentTest = name
        currentTestHadFailure = false
        print("▸ \(name)")
    }

    private static func end() -> Int {
        if currentTestHadFailure {
            print("   → FAILED: \(currentTest)")
            return 1
        }
        return 0
    }

    // MARK: - Parser tests

    /// A real 22-byte report shape: 6 header bytes, then X/Y/Z.
    /// X = 1.0 g, Y = -0.5 g, Z = 0.25 g at scale 65536.
    private static func sampleReport(x: Int32, y: Int32, z: Int32) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: MotionSensorManager.imuReportLen)
        report[0] = 0x02
        report[1] = 0x00
        report[2] = 0x10
        // bytes 3..5 deliberately left as noise so the test also proves the
        // parser does NOT read from there.
        report[3] = 0xAB
        report[4] = 0xCD
        report[5] = 0xEF

        let payload = [x, y, z]
        for (index, value) in payload.enumerated() {
            let base = MotionSensorManager.imuDataOffset + index * 4
            let bits = UInt32(bitPattern: value)
            for byteIndex in 0..<4 {
                report[base + byteIndex] = UInt8((bits >> (8 * UInt32(byteIndex))) & 0xFF)
            }
        }
        return report
    }

    private static func testParseKnownReport() -> Int {
        begin("parseXYZ reads known X/Y/Z at byte offset 6")

        let report = sampleReport(x: 65536, y: -32768, z: 16384)
        guard let parsed = MotionSensorManager.parseXYZ(from: report) else {
            check(false, "parser returned nil for a valid 22-byte report")
            return end()
        }
        check(approx(Double(parsed.x), 1.0), "X == 1.0 g (got \(parsed.x))")
        check(approx(Double(parsed.y), -0.5), "Y == -0.5 g (got \(parsed.y))")
        check(approx(Double(parsed.z), 0.25), "Z == 0.25 g (got \(parsed.z))")

        // Raw counts must round-trip exactly.
        if let raw = MotionSensorManager.parseRawCounts(from: report) {
            check(raw.x == 65536, "raw X count == 65536 (got \(raw.x))")
            check(raw.y == -32768, "raw Y count == -32768 (got \(raw.y))")
            check(raw.z == 16384, "raw Z count == 16384 (got \(raw.z))")
        } else {
            check(false, "parseRawCounts returned nil")
        }
        return end()
    }

    /// The exact bug this file was written for: the old code did
    /// `imuDataOffset / 4` == `6 / 4` == 1, reading bytes 4/8/12 instead of
    /// 6/10/14. Bytes 4 and 5 are filled with 0xAB/0xCD here so a regression to
    /// byte-4 reads produces garbage instead of accidentally passing.
    private static func testParseOffsetRegression() -> Int {
        begin("parseXYZ does NOT read byte 4 (regression guard for 6/4 == 1)")

        let report = sampleReport(x: 65536, y: 0, z: 0)
        guard let parsed = MotionSensorManager.parseXYZ(from: report) else {
            check(false, "parser returned nil")
            return end()
        }
        // If it read from byte 4 it would pick up 0xEF000000-ish garbage as X.
        check(approx(Double(parsed.x), 1.0), "X is clean despite 0xAB/0xCD/0xEF at bytes 3-5")
        check(approx(Double(parsed.y), 0.0), "Y == 0 (got \(parsed.y))")
        check(approx(Double(parsed.z), 0.0), "Z == 0 (got \(parsed.z))")
        return end()
    }

    private static func testParseRejectsShortReport() -> Int {
        begin("parseXYZ rejects a buffer shorter than the 18-byte payload")

        let tooShort = [UInt8](repeating: 0, count: MotionSensorManager.imuDataOffset + MotionSensorManager.imuPayloadLen - 1)
        check(MotionSensorManager.parseXYZ(from: tooShort) == nil, "17-byte buffer rejected")

        let exactlyEnough = [UInt8](repeating: 0, count: MotionSensorManager.imuDataOffset + MotionSensorManager.imuPayloadLen)
        check(MotionSensorManager.parseXYZ(from: exactlyEnough) != nil, "18-byte buffer accepted")

        let empty: [UInt8] = []
        check(MotionSensorManager.parseXYZ(from: empty) == nil, "empty buffer rejected")
        return end()
    }

    /// The device reports raw Int32 counts; g = count / 65536. This is the
    /// assumption flagged as "needs hardware verification" in the source.
    private static func testParseScaling() -> Int {
        begin("g-force scaling divides raw counts by 65536")

        check(MotionSensorManager.accelScale == 65536.0, "accelScale == 65536")

        // A resting Mac at -1 g on Z: -65536 counts.
        let resting = sampleReport(x: 0, y: 0, z: -65536)
        guard let parsed = MotionSensorManager.parseXYZ(from: resting) else {
            check(false, "parser returned nil")
            return end()
        }
        check(approx(Double(parsed.z), -1.0), "resting Z == -1.0 g (got \(parsed.z))")
        check(approx(MotionSensorManager.accelScale / 65536.0, 1.0), "full-scale count == 1 g")
        return end()
    }

    // MARK: - Report geometry tests

    private static func testReportGeometry() -> Int {
        begin("HID report geometry constants")

        check(MotionSensorManager.imuReportLen == 22, "report length == 22 bytes")
        check(MotionSensorManager.imuDataOffset == 6, "payload starts at byte 6")
        check(MotionSensorManager.imuPayloadLen == 12, "payload is 12 bytes (3 × int32)")
        check(
            MotionSensorManager.imuDataOffset + MotionSensorManager.imuPayloadLen <= MotionSensorManager.imuReportLen,
            "payload fits inside the 22-byte report"
        )
        check(
            MotionSensorManager.reportBufSize >= MotionSensorManager.imuReportLen,
            "callback buffer (\(MotionSensorManager.reportBufSize)) >= report length (\(MotionSensorManager.imuReportLen))"
        )
        check(
            MotionSensorManager.reportBufSize % MemoryLayout<Int32>.size == 0,
            "callback buffer is a whole number of int32 words"
        )
        return end()
    }

    // MARK: - Bar geometry tests

    /// The anchoring invariant: the bar must START at the centre marker and
    /// grow outward, never straddle it or start at some fraction of the value.
    ///
    /// The edge adjacent to the marker is the LEADING edge for positive values
    /// and the TRAILING edge for negative ones. The old buggy geometry
    /// ([0.5v, 1.5v] x 150/maxG) failed both halves of this.
    private static func testBarAnchoring() -> Int {
        begin("bar starts at the centre marker and grows outward")

        let g = AxisBarGeometry()
        let values: [Double] = [0, 0.1, 0.5, 1.0, 1.999, 2.0, -0.1, -0.5, -1.0, -2.0]

        for v in values {
            let markerEdge = v >= 0 ? g.leadingEdge(for: v) : g.trailingEdge(for: v)
            check(
                approx(Double(markerEdge), 0.0, tolerance: 1e-6),
                "edge at marker for value \(v) (got \(markerEdge))"
            )
        }

        // The far edge must be exactly the mapped value — no 50% overshoot.
        check(approx(Double(g.trailingEdge(for: 2.0)), 150), "+maxG reaches +150 pt exactly (got \(g.trailingEdge(for: 2.0)))")
        check(approx(Double(g.leadingEdge(for: -2.0)), -150), "-maxG reaches -150 pt exactly (got \(g.leadingEdge(for: -2.0)))")
        check(approx(Double(g.trailingEdge(for: 1.0)), 75), "+half scale reaches +75 pt (got \(g.trailingEdge(for: 1.0)))")
        check(approx(Double(g.leadingEdge(for: -1.0)), -75), "-half scale reaches -75 pt (got \(g.leadingEdge(for: -1.0)))")

        // Sign sanity: the bar extends away from the marker, never toward it.
        for v in values where v > 0 {
            check(g.trailingEdge(for: v) >= 0, "positive \(v) extends right")
        }
        for v in values where v < 0 {
            check(g.leadingEdge(for: v) <= 0, "negative \(v) extends left")
        }

        // Nothing may exceed the half-track on either side.
        for v in values {
            check(
                g.trailingEdge(for: v) <= 150 + 1e-6 && g.leadingEdge(for: v) >= -150 - 1e-6,
                "bar stays inside the track for value \(v)"
            )
        }
        return end()
    }

    private static func testBarClamping() -> Int {
        begin("bar clamps out-of-range values to the track ends")

        let g = AxisBarGeometry()
        check(approx(Double(g.trailingEdge(for: 5.0)), 150), "+5.0 g clamps to the right end (got \(g.trailingEdge(for: 5.0)))")
        check(approx(Double(g.leadingEdge(for: -5.0)), -150), "-5.0 g clamps to the left end (got \(g.leadingEdge(for: -5.0)))")
        check(approx(Double(g.trailingEdge(for: .infinity)), 150), "+infinity clamps to the right end")
        check(approx(Double(g.leadingEdge(for: -.infinity)), -150), "-infinity clamps to the left end")
        check(g.trailingEdge(for: .infinity).isFinite, "clamped infinity stays finite")

        // Zero value still draws a visible nub rather than nothing.
        check(g.width(for: 0) >= g.minWidth, "zero value still has a visible minimum width")
        return end()
    }
}

// MARK: - Entry point

/// `@main` rather than a top-level expression: this file is `SelfTest.swift`,
/// not `main.swift`, so Swift only allows top-level code in `main.swift`.
///
/// Exits 0 when every assertion passes, 1 otherwise, so `build.sh` can gate on it.
@main
struct MotionSensorSelfTestMain {
    static func main() {
        let status = Int32(SelfTest.run())
        exit(status)
    }
}