import AppKit
import CoreGraphics
import Foundation

public extension CursorChanger {
    struct RegistryEntryInfo {
        public let identifier: String
        public let registered: Bool
        public let copyError: Int32
        public let size: CGSize
        public let hotspot: CGPoint
        public let frames: Int
        public let representationCount: Int

        public var line: String {
            "  \(identifier): registered=\(registered) copyErr=\(copyError) size=\(fmtSize) hotspot=(\(fmtHotspot)) frames=\(frames) reps=\(representationCount)"
        }

        private var fmtSize: String { String(format: "%.0fx%.0f", size.width, size.height) }
        private var fmtHotspot: String { String(format: "%.0f,%.0f", hotspot.x, hotspot.y) }
    }

    static func registryEntries(theme: CursorTheme) throws -> [RegistryEntryInfo] {
        // No `try!` here: a missing private symbol must surface as a thrown
        // error, not a trap, even though this path is reachable from `debug`.
        let bridge = try CGSBridge.shared
        let cid = bridge.mainConnectionID()
        var result: [RegistryEntryInfo] = []
        for name in Set(theme.cursors.flatMap { $0.state.cgsNames }).sorted() {
            var size = CGSize.zero
            var hotspot = CGPoint.zero
            var frames: Int = 0
            var duration: CGFloat = 0
            var images: CFArray?
            let copyErr = name.withCString { bridge.copyRegisteredCursorImages(cid, $0, &size, &hotspot, &frames, &duration, &images) }
            result.append(RegistryEntryInfo(
                identifier: "[name] \(name)",
                registered: copyErr == .success,
                copyError: copyErr.rawValue,
                size: size,
                hotspot: hotspot,
                frames: frames,
                representationCount: images.map { CFArrayGetCount($0) } ?? -1
            ))
        }
        for slot in 0...maxCoreCursorSlot {
            var images: CFArray?
            var size = CGSize.zero
            var hotspot = CGPoint.zero
            var frames: Int = 0
            var duration: CGFloat = 0
            let err = bridge.copyCoreCursorImages(cid, Int32(slot), &images, &size, &hotspot, &frames, &duration)
            guard err == .success else {
                continue
            }
            result.append(RegistryEntryInfo(
                identifier: "[slot \(slot)]",
                registered: true,
                copyError: 0,
                size: size,
                hotspot: hotspot,
                frames: frames,
                representationCount: images.map { CFArrayGetCount($0) } ?? -1
            ))
        }
        return result
    }

    static func currentSeed() -> Int32 {
        guard let bridge = try? CGSBridge.shared else { return -1 }
        return bridge.currentCursorSeed()
    }

    /// Seconds spent watching the cursor seed after apply. Short enough to keep
    /// `debug` usable, long enough for a couple of hover transitions.
    static let monitorSeconds = 4

    static func runDiagnostics(theme: CursorTheme, settleDelay: TimeInterval = 0.35) throws -> [String] {
        var out: [String] = []
        func say(_ line: String) { out.append(line) }

        say("=== PRE-APPLY REGISTRY ===")
        try registryEntries(theme: theme).forEach { say($0.line) }
        var baselineSeed = currentSeed()
        say("seed before apply: \(baselineSeed)")

        say("")
        say("=== APPLY ===")
        let report = try apply(theme: theme)
        say(report.summary)

        say("")
        say("=== POST-APPLY REGISTRY ===")
        try registryEntries(theme: theme).forEach { say($0.line) }
        let afterSeed = currentSeed()
        say("seed after apply: \(afterSeed) changed=\(afterSeed != baselineSeed)")
        baselineSeed = afterSeed

        say("")
        say("=== LIVE MONITOR (\(monitorSeconds)s) — hover a text field, a link, the Desktop ===")
        var lastLocation = CGEvent(source: nil)?.location ?? .zero
        for tick in 1...monitorSeconds {
            Thread.sleep(forTimeInterval: 1.0)
            let seed = currentSeed()
            let location = CGEvent(source: nil)?.location ?? .zero
            let moved = location != lastLocation
            lastLocation = location
            if seed != baselineSeed {
                say(String(format: "t=%02ds seed=%d  <-- SEED CHANGED%@", tick, seed, moved ? " (mouse moving)" : ""))
                baselineSeed = seed
            } else {
                say(String(format: "t=%02ds seed=%d%@ ", tick, seed, moved ? " (moving)" : " (idle)"))
            }
        }

        say("")
        say("=== FINAL REGISTRY ===")
        try registryEntries(theme: theme).forEach { say($0.line) }

        say("")
        say("restoring stock cursors (debug always restores on exit)…")
        try restore()
        say("restored stock cursors")
        // Brief settle so the restored cursor is actually drawn before the
        // process exits; this is a delay, not a monitor.
        Thread.sleep(forTimeInterval: settleDelay)
        return out
    }
}

public extension CursorChanger {
    struct OverlayAssets {
        public let cgImages: [CGImage]
        public let pointSize: CGSize
        public let hotspot: CGPoint
    }

    static func overlayAssets(for theme: CursorTheme, state: CursorState = .arrow) -> OverlayAssets? {
        guard let cursor = theme.cursors.first(where: { $0.state == state }) else { return nil }
        guard let images = try? ThemeImageLoader.cgImages(
            oneXURL: cursor.imageFile,
            retinaURL: cursor.retinaFile,
            pointSize: cursor.pointSize
        ) else { return nil }
        return OverlayAssets(cgImages: images, pointSize: cursor.pointSize, hotspot: cursor.hotspot)
    }
}

/// AppKit's drawing context is process-global state (`NSGraphicsContext.current`)
/// and is only safe to mutate on the main thread. Everything that rasterizes
/// cursors funnels through here, on every thread.
public enum CursorChangerRendering {
    /// The thread that first asked for AppKit; treated as the main thread for
    /// the purposes of the precondition below.
    static let renderingThread: Thread = Thread.current

    /// Runs `work` on the main thread and waits, preserving the caller's
    /// synchronous contract. Re-entrant calls run inline to avoid deadlock.
    public static func onMainThread<T>(_ work: () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try work()
        }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = Result { try work() }
        }
        return try result.get()
    }

    public static func assertMainThread(_ function: StaticString = #function) {
        precondition(
            Thread.isMainThread,
            "AppKit cursor rasterization (\(function)) must run on the main thread; use CursorChangerRendering.onMainThread"
        )
    }
}
