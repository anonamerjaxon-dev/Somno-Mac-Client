import AppKit
import CoreGraphics
import Foundation

/// A captured cursor: its images plus how many animation frames they
/// represent. The PNGs written by `capture` are a static cursor's 1x/2x scale
/// variants — NOT animation frames — so the frame count stays 1 even though
/// the image array holds two entries.
typealias CapturedStockCursor = (
    name: String,
    pointSize: CGSize,
    hotspot: CGPoint,
    images: [CGImage],
    frameCount: Int
)

/// `CGSRegisterCursorWithImages` gets 1 for a static cursor. Passing the image
/// count here would make WindowServer treat scale variants as animation frames.
let staticCursorFrameCount = 1

public extension CursorChanger {
    struct CapturedCursor {
        public let name: String
        public let pointSize: CGSize
        public let hotspot: CGPoint
        public let pngFiles: [URL]
    }

    static var stockCaptureDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CursorChanger/SystemDefault", isDirectory: true)
    }

    static func hasStockCapture() -> Bool {
        FileManager.default.fileExists(atPath: stockCaptureDirectory.appendingPathComponent("manifest.json").path)
    }

    static func captureStockCursors() throws -> Int {
        let bridge = try CGSBridge.shared
        let cid = bridge.mainConnectionID()
        let dir = stockCaptureDirectory
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var manifest: [[String: Any]] = []
        var names = Set(CursorState.allCases.flatMap { $0.cgsNames })
        names.formUnion(["com.apple.coregraphics.ArrowS", "com.apple.coregraphics.IBeamS"])

        for name in names.sorted() {
            var size = CGSize.zero
            var hotspot = CGPoint.zero
            var frames: Int = 0
            var duration: CGFloat = 0
            var images: CFArray?
            let err = name.withCString { bridge.copyRegisteredCursorImages(cid, $0, &size, &hotspot, &frames, &duration, &images) }
            guard err == .success, let array = images, CFArrayGetCount(array) > 0 else { continue }

            var files: [String] = []
            for i in 0..<CFArrayGetCount(array) {
                // The CFArray handed back by CGSCopyRegisteredCursorImages is
                // untyped as far as Swift is concerned; check before casting.
                guard let image = cgImageFromCFValue(CFArrayGetValueAtIndex(array, i)) else {
                    diagnosticLogger?("capture: \(name)[\(i)] is not a CGImage — skipped")
                    continue
                }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let fileURL = dir.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "_"))-\(i).png")
                try data.write(to: fileURL)
                files.append(fileURL.lastPathComponent)
            }
            guard !files.isEmpty else { continue }
            manifest.append([
                "name": name,
                "pointSize": [Double(size.width), Double(size.height)],
                "hotspot": [Double(hotspot.x), Double(hotspot.y)],
                // These PNGs are the 1x/2x scale variants of ONE static
                // cursor, not animation frames.
                "frameCount": staticCursorFrameCount,
                "files": files
            ])
        }

        let data = try JSONSerialization.data(withJSONObject: ["cursors": manifest])
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        return manifest.count
    }

    internal static func loadCapturedStockSet() -> [CapturedStockCursor] {
        let dir = stockCaptureDirectory
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["cursors"] as? [[String: Any]] else { return [] }

        var result: [CapturedStockCursor] = []
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let sizeArray = entry["pointSize"] as? [Double], sizeArray.count == 2,
                  let hotArray = entry["hotspot"] as? [Double], hotArray.count == 2,
                  let files = entry["files"] as? [String] else { continue }
            let pointSize = CGSize(width: sizeArray[0], height: sizeArray[1])
            let hotspot = CGPoint(x: hotArray[0], y: hotArray[1])
            // Manifest sizes come from WindowServer; clamp before they reach
            // the rasterizer (STEP 5 / M2).
            guard pointSize.width.isFinite, pointSize.height.isFinite,
                  pointSize.width >= 1, pointSize.height >= 1,
                  pointSize.width <= CursorTheme.maximumCursorPointSize,
                  pointSize.height <= CursorTheme.maximumCursorPointSize else {
                diagnosticLogger?("capture: skipping '\(name)' — implausible size \(pointSize.width)x\(pointSize.height)")
                continue
            }
            let frameCount = max(1, entry["frameCount"] as? Int ?? staticCursorFrameCount)

            var cgImages: [CGImage] = []
            for file in files {
                guard let url = containedURL(for: file, in: dir) else {
                    diagnosticLogger?("capture: manifest path '\(file)' escapes the capture directory — skipped")
                    continue
                }
                guard let image = NSImage(contentsOf: url) else { continue }
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: max(1, Int(pointSize.width * 2)),
                    pixelsHigh: max(1, Int(pointSize.height * 2)),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                rep.size = pointSize
                guard let cgImage = try? CursorChangerRendering.onMainThread({ () -> CGImage? in
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
                    NSGraphicsContext.current = ctx
                    image.draw(in: NSRect(origin: .zero, size: pointSize))
                    ctx.flushGraphics()
                    return rep.cgImage
                }) else { continue }
                cgImages.append(cgImage)
            }
            guard !cgImages.isEmpty else { continue }
            // A captured cursor's PNGs are its 1x/2x scale variants, not an
            // animation, so the frame count is 1 unless the manifest says
            // otherwise — never the image count.
            let effectiveFrameCount = min(frameCount, max(1, cgImages.count))
            result.append((name, pointSize, hotspot, cgImages, effectiveFrameCount))
        }
        return result
    }

    /// Resolves a manifest-relative file name, refusing `../` escapes.
    static func containedURL(for file: String, in directory: URL) -> URL? {
        let base = directory.standardizedFileURL
        let candidate = base.appendingPathComponent(file).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }

    internal static func registerStockSet(bridge: CGSBridge, cid: Int32, instantly: Bool, activate: Bool) -> Int {
        var count = 0
        for captured in loadCapturedStockSet() {
            var seed: Int32 = 0
            let err = captured.name.withCString { cName in
                bridge.registerCursorWithImages(
                    cid, cName, true, instantly,
                    captured.pointSize, captured.hotspot,
                    captured.frameCount, 0,
                    captured.images as CFArray, &seed
                )
            }
            guard err == .success else {
                diagnosticLogger?("capture: registerStockSet('\(captured.name)') err=\(err.rawValue)")
                continue
            }
            count += 1
            if activate {
                var activateSeed: Int32 = 0
                let setErr = captured.name.withCString { bridge.setRegisteredCursor(cid, $0, &activateSeed) }
                if setErr != .success {
                    diagnosticLogger?("capture: setRegisteredCursor('\(captured.name)') err=\(setErr.rawValue)")
                }
                if let slot = CursorChanger.coreSlot(for: captured.name) {
                    let coreErr = bridge.setCoreCursor(cid, slot)
                    if coreErr != .success {
                        diagnosticLogger?("capture: CoreCursorSet(\(captured.name)) err=\(coreErr.rawValue)")
                    }
                }
            }
        }
        return count
    }

    @discardableResult
    static func restoreFromStockCapture() throws -> Int {
        guard !loadCapturedStockSet().isEmpty else {
            throw CursorChangerError.noStockCapture
        }
        let bridge = try CGSBridge.shared
        let cid = bridge.mainConnectionID()
        let restoredCount = registerStockSet(bridge: bridge, cid: cid, instantly: true, activate: true)
        try? nudgeCursorScale()
        return restoredCount
    }
}
