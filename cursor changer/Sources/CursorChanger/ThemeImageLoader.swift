import AppKit
import CoreGraphics

enum ThemeImageError: Error, CustomStringConvertible, LocalizedError {
    case unreadable(String)
    case renderFailed(String)
    case sizeOutOfRange(path: String, pixels: Int, maximum: Int)

    var description: String {
        switch self {
        case .unreadable(let path):
            return "Could not decode image: \(path) (supported: png, svg, jpg, tiff)"
        case .renderFailed(let path):
            return "Could not rasterize: \(path)"
        case .sizeOutOfRange(let path, let pixels, let maximum):
            return "Refusing to rasterize \(path) at \(pixels)x\(pixels)px — the limit is \(maximum)x\(maximum)px per side"
        }
    }

    var errorDescription: String? { description }
}

enum ThemeImageLoader {
    /// Hard cap on a rasterized cursor edge, in pixels. `pointSize × 2` is
    /// unclamped input — a `{"arrow": 100000}` size entry would otherwise ask
    /// for a ~200000² bitmap (~160 GB at 4 bytes/pixel).
    static let maximumPixelsPerSide = 2048

    static func cgImages(oneXURL: URL, retinaURL: URL?, pointSize: CGSize, scales: [CGFloat] = [1.0, 2.0]) throws -> [CGImage] {
        // NSImage decoding and NSGraphicsContext.current mutation are AppKit
        // main-thread work; hop there from any thread.
        try CursorChangerRendering.onMainThread {
            try cgImagesOnMainThread(oneXURL: oneXURL, retinaURL: retinaURL, pointSize: pointSize, scales: scales)
        }
    }

    private static func cgImagesOnMainThread(oneXURL: URL, retinaURL: URL?, pointSize: CGSize, scales: [CGFloat]) throws -> [CGImage] {
        CursorChangerRendering.assertMainThread("ThemeImageLoader.cgImages")

        let source = NSImage(contentsOf: oneXURL)
        let retinaSource = retinaURL.flatMap { NSImage(contentsOf: $0) }
        guard source != nil || retinaSource != nil else {
            throw ThemeImageError.unreadable(oneXURL.path)
        }

        var result: [CGImage] = []
        for scale in scales {
            let chosen: NSImage?
            if scale > 1, retinaSource != nil {
                chosen = retinaSource
            } else {
                chosen = source
            }
            guard let image = chosen else {
                throw ThemeImageError.unreadable(retinaURL?.path ?? oneXURL.path)
            }
            let pixelSize = CGSize(
                width: max(1, round(pointSize.width * scale)),
                height: max(1, round(pointSize.height * scale))
            )
            try Self.validatePixelSize(pixelSize, path: oneXURL.path)
            guard let cg = rasterize(image: image, pixelSize: pixelSize) else {
                throw ThemeImageError.renderFailed(oneXURL.path)
            }
            result.append(cg)
        }
        return result
    }

    /// Refuses absurd bitmaps with a clear error instead of attempting the
    /// allocation. Also guards against non-finite sizes (NaN → Int() traps).
    static func validatePixelSize(_ pixelSize: CGSize, path: String) throws {
        let width = pixelSize.width
        let height = pixelSize.height
        guard width.isFinite, height.isFinite else {
            throw ThemeImageError.renderFailed("\(path) (non-finite size \(width)x\(height))")
        }
        let pixels = max(Int(width.rounded(.down)), Int(height.rounded(.down)))
        guard pixels <= maximumPixelsPerSide else {
            throw ThemeImageError.sizeOutOfRange(path: path, pixels: pixels, maximum: maximumPixelsPerSide)
        }
    }

    /// Main-thread only: mutates `NSGraphicsContext.current`, which is
    /// process-global AppKit state.
    private static func rasterize(image: NSImage, pixelSize: CGSize) -> CGImage? {
        CursorChangerRendering.assertMainThread("ThemeImageLoader.rasterize")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx

        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        let fitScale = min(pixelSize.width / sourceSize.width, pixelSize.height / sourceSize.height)
        let drawSize = NSSize(
            width: sourceSize.width * fitScale,
            height: sourceSize.height * fitScale
        )
        let drawOrigin = NSPoint(
            x: (pixelSize.width - drawSize.width) / 2,
            y: (pixelSize.height - drawSize.height) / 2
        )
        image.draw(
            in: NSRect(origin: drawOrigin, size: drawSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1.0
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}
