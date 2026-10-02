import AppKit
import Foundation
@testable import CursorChanger

// MARK: - Honest assertion harness
//
// Two properties this file must hold:
//  1. A thrown error is a FAILURE. `try? testX()` used to swallow an entire
//     test silently; now suite bodies are `throws` and `runSuite` reports a
//     suite that threw.
//  2. Per-suite counters are independent. The old global counter made each
//     suite print the running total, so "5 failures" under suite 4 really
//     meant "4 failures so far, 1 in this suite".

struct SuiteResult {
    let name: String
    let assertions: Int
    let failures: Int
    let threw: Error?

    var passed: Int { assertions - failures }
}

final class Counter {
    private let lock = NSLock()
    private var _assertions = 0
    private var _failures = 0

    var assertions: Int {
        lock.lock(); defer { lock.unlock() }
        return _assertions
    }

    var failures: Int {
        lock.lock(); defer { lock.unlock() }
        return _failures
    }

    func record(failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        _assertions += 1
        if failed { _failures += 1 }
    }

    func reset() {
        lock.lock()
        _assertions = 0
        _failures = 0
        lock.unlock()
    }
}

let currentCounter = Counter()

func XCTAssert(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let ok = condition()
    currentCounter.record(failed: !ok)
    if !ok {
        print("  FAIL: \(message()) at \(file):\(line)")
    }
}

func XCTAssertFalse(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssert(!condition(), message(), file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let left = lhs()
    let right = rhs()
    let equal = left == right
    currentCounter.record(failed: !equal)
    if !equal {
        print("  FAIL: \(message()) — expected \(right), got \(left) at \(file):\(line)")
    }
}

func XCTAssertTrue(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssert(condition(), message(), file: file, line: line)
}

func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let unwrapped = value()
    currentCounter.record(failed: unwrapped != nil)
    if unwrapped != nil {
        print("  FAIL: \(message()) at \(file):\(line)")
    }
}

func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let unwrapped = value()
    currentCounter.record(failed: unwrapped == nil)
    if unwrapped == nil {
        print("  FAIL: \(message()) at \(file):\(line)")
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    currentCounter.record(failed: false)
    do {
        _ = try expression()
        currentCounter.record(failed: true)
        print("  FAIL: \(message()) — expected error at \(file):\(line)")
    } catch {}
}

/// Asserts that `expression` throws a specific `LocalizedError` message. This
/// is what proves the M3 fix: before it, `error.localizedDescription` read
/// "The operation couldn't be completed…".
func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    containing expected: String,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        currentCounter.record(failed: true)
        print("  FAIL: \(message()) — expected error containing '\(expected)' at \(file):\(line)")
    } catch {
        let text = error.localizedDescription
        currentCounter.record(failed: !text.contains(expected))
        if !text.contains(expected) {
            print("  FAIL: \(message()) — localizedDescription was '\(text)', expected it to contain '\(expected)'")
        }
    }
}

/// The mirror of `XCTAssertThrowsError`: used to prove that a call which must
/// *not* trap (e.g. `CGSBridge.shared` after the `try!` was removed) really
/// returns or throws rather than aborting the process.
func XCTAssertNoThrowError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        currentCounter.record(failed: false)
    } catch {
        currentCounter.record(failed: true)
        print("  FAIL: \(message()) — unexpected error: \(error.localizedDescription) at \(file):\(line)")
    }
}

var suiteResults: [SuiteResult] = []

@discardableResult
func runSuite(_ name: String, tests: () throws -> Void) -> SuiteResult {
    currentCounter.reset()
    var thrown: Error?
    do {
        try tests()
    } catch {
        // A thrown error is a failure, not a silent skip.
        thrown = error
        currentCounter.record(failed: true)
        print("  FAIL: suite '\(name)' threw: \(error.localizedDescription)")
    }
    let result = SuiteResult(
        name: name,
        assertions: currentCounter.assertions,
        failures: currentCounter.failures,
        threw: thrown
    )
    suiteResults.append(result)
    print("\n=== \(name) ===")
    print("\(result.assertions) assertions, \(result.passed) passed, \(result.failures) failed")
    return result
}

// MARK: - Fixtures

let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("cursor-changer-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// Deletes every fixture directory the suites created. Runs on both the success
/// and failure path so a crashed run does not leave temp dirs behind.
func cleanupTempDirs() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: tempRoot.path) else { return }
    if let names = try? fm.contentsOfDirectory(atPath: tempRoot.path) {
        for name in names {
            try? fm.removeItem(at: tempRoot.appendingPathComponent(name))
        }
    }
    try? fm.removeItem(at: tempRoot)
}

func makePNG(width: Int, height: Int, at url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - CursorStateMapping

func testStateMappingComplete() {
    for state in CursorState.allCases {
        XCTAssert(!state.cgsNames.isEmpty, "\(state.rawValue) must map to at least one CGS name")
        for name in state.cgsNames {
            XCTAssertTrue(name.hasPrefix("com.apple."), "\(name) should be namespaced")
        }
    }
    let stems = Set(CursorState.allCases.map(\.rawValue))
    XCTAssertEqual(stems.count, CursorState.allCases.count, "state raw values must be unique")
}

func testCoreSlotParsing() {
    XCTAssertEqual(CursorChanger.coreSlot(for: "com.apple.cursor.0"), 0)
    XCTAssertEqual(CursorChanger.coreSlot(for: "com.apple.cursor.39"), 39)
    XCTAssertNil(CursorChanger.coreSlot(for: "com.apple.coregraphics.Arrow"))
    XCTAssertNil(CursorChanger.coreSlot(for: "com.apple.cursor.notANumber"))
    for state in CursorState.allCases {
        for name in state.cgsNames where name.hasPrefix("com.apple.cursor.") {
            let slot = CursorChanger.coreSlot(for: name)
            XCTAssertNotNil(slot, "\(name) must yield a slot")
            XCTAssert(slot! <= Int32(CursorChanger.maxCoreCursorSlot), "\(name) slot \(slot!) must be <= \(CursorChanger.maxCoreCursorSlot)")
        }
    }
}

// MARK: - CursorTheme

func testThemeMinimalArrowOnly() throws {
    let dir = tempRoot.appendingPathComponent("minimal")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 16, height: 16, at: dir.appendingPathComponent("arrow.png"))

    let theme = try CursorTheme.load(directory: dir)
    XCTAssertEqual(theme.name, "minimal")
    XCTAssertEqual(theme.cursors.count, 1)
    XCTAssertEqual(theme.cursors[0].state, .arrow)
}

func testThemeMissingArrowThrows() throws {
    let dir = tempRoot.appendingPathComponent("noarrow")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("ibeam.png"))
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "missing arrow must throw")
    XCTAssertThrowsError(
        try CursorTheme.load(directory: dir),
        containing: "arrow.png",
        "missing-arrow error must read clearly"
    )
}

func testThemeMissingDirectoryThrows() throws {
    let dir = tempRoot.appendingPathComponent("does-not-exist")
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "missing folder must throw")
    XCTAssertThrowsError(
        try CursorTheme.load(directory: dir),
        containing: "Skin folder not found",
        "missing-folder error must name the problem"
    )
}

func testThemeUnknownHotspotKeyThrows() throws {
    let dir = tempRoot.appendingPathComponent("badkey")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    try "{\"hotspots\": {\"notAState\": [1,2]}}".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "unknown hotspot key must throw")
    XCTAssertThrowsError(
        try CursorTheme.load(directory: dir),
        containing: "notAState",
        "unknown-key error must echo the offending key"
    )
}

func testThemeUnknownSizeKeyThrows() throws {
    let dir = tempRoot.appendingPathComponent("badsizekey")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    try "{\"sizes\": {\"notAState\": 24}}".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "unknown size key must throw")
}

func testThemeOversizedSizeThrows() throws {
    // M2: an uncapped `sizes` entry used to reach the 2x rasterizer and ask
    // for a ~200000px square bitmap.
    let dir = tempRoot.appendingPathComponent("hugesize")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    try "{\"sizes\": {\"arrow\": 100000}}".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "a 100000pt cursor must be rejected at load")
    XCTAssertThrowsError(
        try CursorTheme.load(directory: dir),
        containing: "must be between",
        "oversize error must state the accepted range"
    )

    try "{\"sizes\": {\"arrow\": 0}}".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "a 0pt cursor must be rejected at load")
}

func testThemeMaximumSizeAccepted() throws {
    let dir = tempRoot.appendingPathComponent("maxsize")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    try "{\"sizes\": {\"arrow\": 1024}}".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    let theme = try CursorTheme.load(directory: dir)
    XCTAssertEqual(theme.cursors[0].pointSize.width, 1024, "the upper bound itself must still load")
}

func testThemeTildeExpansion() throws {
    // The README shows `~/Skins/tuff`, but URL(fileURLWithPath:) does not
    // expand `~`, so that example never worked.
    let home = NSHomeDirectory()
    let expanded = CursorTheme.expandSkinPath("~/Skins/tuff")
    XCTAssertFalse(expanded.path.hasPrefix("~"), "expandSkinPath must drop the tilde")
    XCTAssertEqual(expanded.path, (home as NSString).appendingPathComponent("Skins/tuff"))

    let dir = tempRoot.appendingPathComponent("tildedir")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    XCTAssertEqual(CursorTheme.expandSkinPath(dir.path).path, dir.standardizedFileURL.path)

    let missing = tempRoot.appendingPathComponent("nope")
    XCTAssertThrowsError(
        try CursorTheme.load(skinPath: missing.path),
        containing: "Skin folder not found",
        "load(skinPath:) must report a clean error"
    )
}

func testThemeOverridesAndDefaults() throws {
    let dir = tempRoot.appendingPathComponent("overrides")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 64, height: 64, at: dir.appendingPathComponent("arrow.png"))
    try makePNG(width: 16, height: 16, at: dir.appendingPathComponent("pointingHand.png"))
    try makePNG(width: 32, height: 32, at: dir.appendingPathComponent("pointingHand@2x.png"))
    try """
    {"name": "Tuff", "hotspots": {"arrow": [3, 1]}, "sizes": {"arrow": 24}}
    """.write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)

    let theme = try CursorTheme.load(directory: dir)
    XCTAssertEqual(theme.name, "Tuff")
    let arrow = theme.cursors.first { $0.state == .arrow }!
    XCTAssertEqual(arrow.hotspot.x, 3)
    XCTAssertEqual(arrow.hotspot.y, 1)
    XCTAssertEqual(arrow.pointSize.width, 24)

    let hand = theme.cursors.first { $0.state == .pointingHand }!
    let systemHand = NSCursor.pointingHand
    XCTAssertEqual(hand.pointSize.width, systemHand.image.size.width)
    XCTAssertEqual(hand.hotspot, systemHand.hotSpot)
    XCTAssertNotNil(hand.retinaFile)
}

func testThemeMalformedJSONThrows() throws {
    let dir = tempRoot.appendingPathComponent("badjson")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try makePNG(width: 8, height: 8, at: dir.appendingPathComponent("arrow.png"))
    try "{not json".write(to: dir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try CursorTheme.load(directory: dir), "malformed theme.json must throw")
    XCTAssertThrowsError(
        try CursorTheme.load(directory: dir),
        containing: "theme.json is malformed",
        "JSON error must name the file"
    )
}

// MARK: - ThemeImageLoader

func testLoaderProducesScaledReps() throws {
    let dir = tempRoot.appendingPathComponent("loader")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = dir.appendingPathComponent("arrow.png")
    try makePNG(width: 10, height: 20, at: png)

    let images = try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: 16, height: 32))
    XCTAssertEqual(images.count, 2)
    XCTAssertEqual(images[0].width, 16)
    XCTAssertEqual(images[0].height, 32)
    XCTAssertEqual(images[1].width, 32)
    XCTAssertEqual(images[1].height, 64)
}

func testLoaderRefusesAbsurdBitmap() throws {
    let dir = tempRoot.appendingPathComponent("toolarge")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = dir.appendingPathComponent("arrow.png")
    try makePNG(width: 8, height: 8, at: png)

    // 100000pt at 2x: the old code passed this straight to NSBitmapImageRep.
    XCTAssertThrowsError(
        try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: 100_000, height: 100_000)),
        "a 100000pt cursor must not be rasterized"
    )
    XCTAssertThrowsError(
        try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: 100_000, height: 100_000)),
        containing: "Refusing to rasterize",
        "the refusal must say what it refused"
    )
    // Exactly at the cap is still allowed.
    XCTAssertNoThrowError(
        try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: 1024, height: 1024)),
        "1024pt (2048px at 2x) is at the cap and must load"
    )
    // Non-finite sizes must throw rather than trap in Int().
    XCTAssertThrowsError(
        try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: CGFloat.infinity, height: 32)),
        "infinite size must throw"
    )
}

func testLoaderMissingImageThrows() {
    let missing = tempRoot.appendingPathComponent("nope/arrow.png")
    XCTAssertThrowsError(
        try ThemeImageLoader.cgImages(oneXURL: missing, retinaURL: nil, pointSize: CGSize(width: 16, height: 16)),
        "a missing file must throw"
    )
    XCTAssertThrowsError(
        try ThemeImageLoader.cgImages(oneXURL: missing, retinaURL: nil, pointSize: CGSize(width: 16, height: 16)),
        containing: "Could not decode image",
        "unreadable-image error must explain itself"
    )
}

func testLoaderWorksOffMainThread() throws {
    // M4: rasterize mutates NSGraphicsContext.current; it must hop to main
    // rather than corrupt whatever context the caller had.
    let dir = tempRoot.appendingPathComponent("offmain")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = dir.appendingPathComponent("arrow.png")
    try makePNG(width: 12, height: 12, at: png)

    let done = DispatchSemaphore(value: 0)
    var result: Result<[CGImage], Error>!
    DispatchQueue.global().async {
        result = Result {
            try ThemeImageLoader.cgImages(oneXURL: png, retinaURL: nil, pointSize: CGSize(width: 16, height: 16))
        }
        done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "background rasterize must finish")
    switch result! {
    case .success(let images):
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].width, 16)
    case .failure(let error):
        XCTAssertFalse(true, "background rasterize failed: \(error)")
    }
}

func testSVGLoading() throws {
    let dir = tempRoot.appendingPathComponent("svg")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="24" viewBox="0 0 16 24">
      <path d="M2 2 L2 22 M14 2 L14 22 M2 2 L14 2" stroke="#2563eb" stroke-width="2" fill="none"/>
    </svg>
    """
    try svg.write(to: dir.appendingPathComponent("ibeam.svg"), atomically: true, encoding: .utf8)
    try makePNG(width: 16, height: 16, at: dir.appendingPathComponent("arrow.png"))

    let theme = try CursorTheme.load(directory: dir)
    let ibeam = theme.cursors.first { $0.state == .ibeam }
    XCTAssertNotNil(ibeam, "svg ibeam must be discovered")

    let images = try ThemeImageLoader.cgImages(oneXURL: ibeam!.imageFile, retinaURL: nil, pointSize: CGSize(width: 12, height: 18))
    XCTAssertEqual(images[0].width, 12)
    XCTAssertEqual(images[0].height, 18)
}

// MARK: - Errors (M3)

func testErrorsAreLocalized() {
    // Every public error type must be a LocalizedError, otherwise
    // `localizedDescription` degrades to "The operation couldn't be
    // completed…" at the demo/agent call sites.
    let errors: [Error] = [
        CursorChangerError.bridgeUnavailable,
        CursorChangerError.bridgeLoadFailed("symbol missing"),
        CursorChangerError.restoreFailed(CGError(rawValue: 1)!),
        CursorChangerError.noStockCapture,
        CursorChangerRegistrationError(code: CGError(rawValue: 2)!, name: "com.apple.coregraphics.Arrow"),
        ThemeError.directoryNotFound("/tmp/x"),
        ThemeError.missingArrow,
        ThemeError.unreadableImage("/tmp/x.png"),
        ThemeError.invalidHotspotKey("nope"),
        ThemeError.invalidSizeKey("nope"),
        ThemeError.malformedThemeJSON("bad"),
        ThemeError.sizeOutOfRange(state: "arrow", requested: 100_000, minimum: 1, maximum: 1024),
        ThemeError.imageTooLarge(path: "/tmp/x.png", pixels: 200_000, maximum: 2048),
        ThemeImageError.unreadable("/tmp/x.png"),
        ThemeImageError.renderFailed("/tmp/x.png"),
        ThemeImageError.sizeOutOfRange(path: "/tmp/x.png", pixels: 100_000, maximum: 2048),
        CGSBridgeError.libraryLoadFailed("/nope"),
        CGSBridgeError.symbolUnavailable("CGSFoo")
    ]
    for error in errors {
        XCTAssertTrue(error is LocalizedError, "\(type(of: error)) must be a LocalizedError")
        let localized = error.localizedDescription
        XCTAssertFalse(
            localized.hasPrefix("The operation couldn't be completed"),
            "\(type(of: error)).localizedDescription fell back to the generic message"
        )
        XCTAssertFalse(localized.isEmpty, "\(type(of: error)).localizedDescription must not be empty")
    }

    XCTAssertEqual(
        CursorChangerError.noStockCapture.localizedDescription,
        "No stock capture found — run CursorChangerCLI capture on a clean session (or reboot) first"
    )
    XCTAssertEqual(
        CursorChangerRegistrationError(code: CGError(rawValue: 7)!, name: "com.apple.cursor.0").localizedDescription,
        "CGError 7 registering cursor 'com.apple.cursor.0'"
    )
}

func testApplyReportSummarizesWithRealMessages() {
    let ok = ApplyReport(entries: [
        .init(state: .arrow, cgsName: "a", error: nil),
        .init(state: .ibeam, cgsName: "b", error: nil)
    ])
    XCTAssertTrue(ok.isSuccess)
    XCTAssertEqual(ok.summary, "Applied 2 cursor(s) successfully")

    let partial = ApplyReport(entries: [
        .init(state: .arrow, cgsName: "a", error: nil),
        .init(state: .ibeam, cgsName: "b", error: CursorChangerRegistrationError(code: CGError(rawValue: 3)!, name: "b"))
    ])
    XCTAssertFalse(partial.isSuccess)
    XCTAssertEqual(partial.failures.count, 1)
    XCTAssertTrue(
        partial.summary.contains("CGError 3 registering cursor 'b'"),
        "ApplyReport.summary must carry the real message, got: \(partial.summary)"
    )
    XCTAssertFalse(
        partial.summary.contains("The operation couldn't be completed"),
        "ApplyReport.summary must not degrade to the generic message"
    )
}

// MARK: - StockCapture hardening

func testManifestPathTraversalRefused() throws {
    let base = tempRoot.appendingPathComponent("traversal")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    XCTAssertNotNil(CursorChanger.containedURL(for: "arrow-0.png", in: base))
    XCTAssertNil(CursorChanger.containedURL(for: "../escape.png", in: base))
    XCTAssertNil(CursorChanger.containedURL(for: "sub/../../escape.png", in: base))
    XCTAssertNil(CursorChanger.containedURL(for: "/etc/passwd", in: base))
    XCTAssertNil(CursorChanger.containedURL(for: "", in: base))
}

func testStaticCursorFrameCount() {
    // A captured cursor's images are scale variants, not animation frames.
    XCTAssertEqual(staticCursorFrameCount, 1)
    XCTAssertEqual(CursorChanger.maxCoreCursorSlot, 43)
}

// MARK: - CGSBridge (M1)

func testBridgeNoCrashAndHonestErrors() {
    // M1: `CGSBridge.shared` used to be `try! CGSBridge()` reachable from the
    // CLI `debug` command. It must now be a throwing accessor.
    XCTAssertNoThrowError(
        try CGSBridge.shared,
        "shared must not trap; it either resolves or throws"
    )
    if let bridge = try? CGSBridge.shared {
        XCTAssertNoThrowError(try { _ = bridge.mainConnectionID() }(), "mainConnectionID must be callable")
    }
    if CGSBridge.isAvailable() {
        XCTAssertNotNil(try? CGSBridge.shared.mainConnectionID(), "main connection id should resolve")
    } else {
        print("  SKIP: CGS bridge unavailable on this OS")
        // A failure here must still be explainable, not a bare "unavailable".
        XCTAssertNotNil(CursorChanger.requireBridgeErrorDescription() ?? "unavailable", "bridge unavailability must have a message")
    }
}

// MARK: - Run

func runAllSuites() {
    runSuite("CursorStateMapping") {
        testStateMappingComplete()
        testCoreSlotParsing()
    }

    runSuite("CursorTheme") {
        try testThemeMinimalArrowOnly()
        try testThemeMissingArrowThrows()
        try testThemeMissingDirectoryThrows()
        try testThemeUnknownHotspotKeyThrows()
        try testThemeUnknownSizeKeyThrows()
        try testThemeOversizedSizeThrows()
        try testThemeMaximumSizeAccepted()
        try testThemeTildeExpansion()
        try testThemeOverridesAndDefaults()
        try testThemeMalformedJSONThrows()
    }

    runSuite("ThemeImageLoader") {
        try testLoaderProducesScaledReps()
        try testLoaderRefusesAbsurdBitmap()
        testLoaderMissingImageThrows()
        try testLoaderWorksOffMainThread()
        try testSVGLoading()
    }

    runSuite("Errors") {
        testErrorsAreLocalized()
        testApplyReportSummarizesWithRealMessages()
    }

    runSuite("StockCapture") {
        try testManifestPathTraversalRefused()
        testStaticCursorFrameCount()
    }

    runSuite("CGSBridge") {
        testBridgeNoCrashAndHonestErrors()
    }
}

let tempRootWasClean = !FileManager.default.fileExists(atPath: tempRoot.path)
try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { cleanupTempDirs() }

runAllSuites()

let totalAssertions = suiteResults.reduce(0) { $0 + $1.assertions }
let totalFailures = suiteResults.reduce(0) { $0 + $1.failures }
let suitesThatThrew = suiteResults.filter { $0.threw != nil }

print("")
print("Suites: \(suiteResults.count) (\(suiteResults.count - suitesThatThrew.count) clean, \(suitesThatThrew.count) threw)")
print("Total: \(totalAssertions) assertions, \(totalFailures) failed")
print("Temp fixtures removed: \(!FileManager.default.fileExists(atPath: tempRoot.path))")
if totalFailures > 0 {
    print("RESULT: FAIL")
    exit(1)
}
print("RESULT: PASS")