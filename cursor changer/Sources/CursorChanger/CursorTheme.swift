import AppKit
import Foundation

public enum ThemeError: Error, CustomStringConvertible, LocalizedError {
    case directoryNotFound(String)
    case missingArrow
    case unreadableImage(String)
    case invalidHotspotKey(String)
    case invalidSizeKey(String)
    case malformedThemeJSON(String)
    case sizeOutOfRange(state: String, requested: CGFloat, minimum: CGFloat, maximum: CGFloat)
    case imageTooLarge(path: String, pixels: Int, maximum: Int)

    public var description: String {
        switch self {
        case .directoryNotFound(let path):
            return "Skin folder not found: \(path)"
        case .missingArrow:
            return "Every skin needs at least arrow.png (or .svg) — the default pointer is required"
        case .unreadableImage(let file):
            return "Could not read image: \(file)"
        case .invalidHotspotKey(let key):
            return "Unknown cursor state '\(key)' in theme.json hotspots"
        case .invalidSizeKey(let key):
            return "Unknown cursor state '\(key)' in theme.json sizes"
        case .malformedThemeJSON(let reason):
            return "theme.json is malformed: \(reason)"
        case .sizeOutOfRange(let state, let requested, let minimum, let maximum):
            return "theme.json size for '\(state)' is \(requested)pt — must be between \(minimum) and \(maximum)pt"
        case .imageTooLarge(let path, let pixels, let maximum):
            return "Image \(path) requests a \(pixels)x\(pixels)px bitmap — the limit is \(maximum)x\(maximum)px per side"
        }
    }

    public var errorDescription: String? { description }
}

public struct ResolvedCursor {
    public let state: CursorState
    public let imageFile: URL
    public let retinaFile: URL?
    public let pointSize: CGSize
    public let hotspot: CGPoint
}

public struct CursorTheme {
    public let name: String
    public let directory: URL
    public let cursors: [ResolvedCursor]

    /// Sanity bounds for a `theme.json` `sizes` entry, in points. A cursor
    /// bigger than the upper bound is a typo, and rasterizing it at 2x would
    /// try to allocate a bitmap larger than any screen.
    public static let minimumCursorPointSize: CGFloat = 1
    public static let maximumCursorPointSize: CGFloat = 1024

    /// Hard cap on a rasterized cursor's edge, in pixels. At 4 bytes/pixel a
    /// 2048pt cursor at 2x would ask for a ~200 MB bitmap.
    public static let maximumImagePixels: Int = 2048

    public static func load(directory: URL) throws -> CursorTheme {
        var isDirectory: ObjCBool = false
        let expandedDirectory = directory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: expandedDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ThemeError.directoryNotFound(directory.path)
        }

        let metaFile = expandedDirectory.appendingPathComponent("theme.json")
        var name = expandedDirectory.lastPathComponent
        var hotspotOverrides: [String: [CGFloat]] = [:]
        var sizeOverrides: [String: CGFloat] = [:]

        if FileManager.default.fileExists(atPath: metaFile.path) {
            let raw: Any
            do {
                raw = try JSONSerialization.jsonObject(with: Data(contentsOf: metaFile))
            } catch {
                throw ThemeError.malformedThemeJSON(error.localizedDescription)
            }
            guard let dict = raw as? [String: Any] else {
                throw ThemeError.malformedThemeJSON("root must be an object")
            }
            if let n = dict["name"] as? String { name = n }
            if let hotspots = dict["hotspots"] as? [String: [CGFloat]] { hotspotOverrides = hotspots }
            if let sizes = dict["sizes"] as? [String: CGFloat] { sizeOverrides = sizes }
        }

        for (key, value) in hotspotOverrides {
            guard CursorState(rawValue: key) != nil else { throw ThemeError.invalidHotspotKey(key) }
            guard value.count == 2 else { throw ThemeError.malformedThemeJSON("hotspot for '\(key)' must be [x, y]") }
        }
        for (key, value) in sizeOverrides {
            guard CursorState(rawValue: key) != nil else { throw ThemeError.invalidSizeKey(key) }
            // Reject absurd values at load time instead of letting the 2x
            // rasterizer try to allocate a ~200000px square bitmap.
            guard value.isFinite, value >= Self.minimumCursorPointSize, value <= Self.maximumCursorPointSize else {
                throw ThemeError.sizeOutOfRange(
                    state: key,
                    requested: value,
                    minimum: Self.minimumCursorPointSize,
                    maximum: Self.maximumCursorPointSize
                )
            }
        }

        var cursors: [ResolvedCursor] = []
        for state in CursorState.allCases {
            // Single discovery pass — this used to call findImage twice and
            // force-unwrap the second result.
            guard let files = Self.findImage(for: state, in: expandedDirectory) else { continue }
            let pointSize = try Self.resolvePointSize(for: state, override: sizeOverrides[state.rawValue], oneXURL: files.oneX)
            let hotspot = try Self.resolveHotspot(for: state, override: hotspotOverrides[state.rawValue].map { CGPoint(x: $0[0], y: $0[1]) }, pointSize: pointSize)
            cursors.append(ResolvedCursor(state: state, imageFile: files.oneX, retinaFile: files.twoX, pointSize: pointSize, hotspot: hotspot))
        }

        guard cursors.contains(where: { $0.state == .arrow }) else {
            throw ThemeError.missingArrow
        }

        return CursorTheme(name: name, directory: expandedDirectory, cursors: cursors)
    }

    private static func findImage(for state: CursorState, in directory: URL) -> (oneX: URL, twoX: URL?)? {
        for ext in CursorState.fileExtensions {
            let url = directory.appendingPathComponent("\(state.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                var twoX: URL?
                for twoExt in CursorState.fileExtensions {
                    let candidate = directory.appendingPathComponent("\(state.rawValue)@2x.\(twoExt)")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        twoX = candidate
                        break
                    }
                }
                return (url, twoX)
            }
        }
        return nil
    }

    private static func resolvePointSize(for state: CursorState, override: CGFloat?, oneXURL: URL) throws -> CGSize {
        if let override = override {
            return CGSize(width: override, height: override)
        }
        if let system = state.systemCursor?.image.size, system.width > 0 {
            return system
        }
        guard let image = NSImage(contentsOf: oneXURL) else {
            throw ThemeError.unreadableImage(oneXURL.path)
        }
        let size = image.size
        return CGSize(width: min(size.width, 32), height: min(size.height, 32))
    }

    /// Expands a leading `~` in a skin path. `URL(fileURLWithPath:)` does NOT
    /// do this, so the README's `~/Skins/tuff` example silently failed.
    public static func expandSkinPath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// `load` with tilde expansion, so `~/Skins/tuff` from the README works.
    public static func load(skinPath: String) throws -> CursorTheme {
        try load(directory: expandSkinPath(skinPath))
    }

    private static func resolveHotspot(for state: CursorState, override: CGPoint?, pointSize: CGSize) throws -> CGPoint {
        if let override = override {
            return override
        }
        if let system = state.systemCursor?.hotSpot {
            return system
        }
        return CGPoint(x: pointSize.width / 2, y: pointSize.height / 2)
    }
}
