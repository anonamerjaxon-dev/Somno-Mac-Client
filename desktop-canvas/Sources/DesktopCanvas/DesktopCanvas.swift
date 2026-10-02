import AppKit

public enum ApplyResult {
    case ok
    case warning(String)
    case error(String)
}

public struct PresetInfo: Identifiable {
    public var id: String { name }
    public let name: String
    public let canvasCount: Int
    public let modifiedAt: Date
}

public final class DesktopCanvas {
    public static let shared = DesktopCanvas()

    private var screenManager: ScreenManager?

    private init() {}

    @discardableResult
    public func apply(layout: CanvasLayout) -> ApplyResult {
        let overlaps = OverlapResolver.detectOverlaps(in: layout.canvases)
        if !overlaps.isEmpty {
            let ids = overlaps.map { "\($0.0) & \($0.1)" }.joined(separator: ", ")
            return .error("Layout contains \(overlaps.count) overlapping canvas(es): \(ids). Separate or remove overlapping canvases before applying.")
        }

        let totalCells = layout.canvases.reduce(0) { count, canvas in
            guard canvas.type == .gameOfLife, let config = canvas.gameOfLifeConfig else {
                return count
            }
            let (cols, rows) = GameOfLifeConfig.gridDimensions(for: canvas.frame, cellSize: config.cellSize)
            return count + (cols * rows)
        }

        stop()

        let manager = ScreenManager()
        manager.applyEmbedded(layout: layout)
        self.screenManager = manager

        Self.saveLastUsedPreset(layout)

        if totalCells > 10_000_000 {
            return .warning("Total Game of Life cells (\(totalCells)) exceeds recommended limit of 10M. Performance may degrade.")
        }
        return .ok
    }

    public func stop() {
        screenManager?.stop()
        screenManager = nil
    }

    public func refresh(with layout: CanvasLayout? = nil) {
        screenManager?.refresh(with: layout)
    }

    public func withGoLProvider(for canvasID: UUID, body: (GameOfLifeProvider) -> Void) {
        guard let provider = screenManager?.provider(for: canvasID, as: GameOfLifeProvider.self) else {
            return
        }
        body(provider)
    }

    public func savePreset(_ layout: CanvasLayout, named name: String) throws {
        let url = Self.presetsDirectory().appendingPathComponent("\(name).json")
        try layout.save(to: url)
        Self.invalidatePresetCache()
    }

    public func loadPreset(named name: String) throws -> CanvasLayout {
        let url = Self.presetsDirectory().appendingPathComponent("\(name).json")
        return try CanvasLayout.load(from: url)
    }

    public func deletePreset(named name: String) throws {
        let url = Self.presetsDirectory().appendingPathComponent("\(name).json")
        try FileManager.default.removeItem(at: url)
        Self.invalidatePresetCache()
    }

    public func listPresets() -> [String] {
        let dir = Self.presetsDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "_last_used.json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Decoded layouts cached by (path, modification date) so that repeatedly
    /// rendering the preset list does not re-parse every file.
    private static var presetDecodeCache: [String: (mtime: Date, canvasCount: Int)] = [:]
    private static let presetCacheLock = NSLock()

    /// File modification timestamps have sub-second resolution on APFS; compare
    /// them with a tolerance so a cache hit is never lost to a rounding
    /// difference between two `resourceValues` reads.
    private static func modificationDatesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1.0
    }

    /// Drops the decoded-preset cache. Called after any write so a re-read sees
    /// the new file.
    private static func invalidatePresetCache() {
        presetCacheLock.lock()
        presetDecodeCache.removeAll()
        presetCacheLock.unlock()
    }

    public func listPresetsWithMetadata() -> [PresetInfo] {
        let dir = Self.presetsDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "_last_used.json" }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let count = Self.cachedCanvasCount(for: url, modifiedAt: modifiedAt)
                return PresetInfo(name: name, canvasCount: count, modifiedAt: modifiedAt)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Returns the canvas count for a preset file, decoding only when the file
    /// changed since it was last decoded.
    private static func cachedCanvasCount(for url: URL, modifiedAt: Date) -> Int {
        let key = url.path
        presetCacheLock.lock()
        if let cached = presetDecodeCache[key],
           Self.modificationDatesMatch(cached.mtime, modifiedAt) {
            presetCacheLock.unlock()
            return cached.canvasCount
        }
        presetCacheLock.unlock()

        let count = (try? CanvasLayout.load(from: url))?.canvases.count ?? 0

        presetCacheLock.lock()
        presetDecodeCache[key] = (mtime: modifiedAt, canvasCount: count)
        presetCacheLock.unlock()
        return count
    }

    public static func presetsDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DesktopCanvas/presets", isDirectory: true)
    }

    public static func lastUsedPresetURL() -> URL {
        presetsDirectory().appendingPathComponent("_last_used.json")
    }

    public static func saveLastUsedPreset(_ layout: CanvasLayout) {
        let dir = presetsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = lastUsedPresetURL()
        // L8: skip the write when the content is unchanged, so a frame-only drag
        // no longer rewrites the file on every mouse-up.
        if let existing = try? Data(contentsOf: url),
           let encoded = try? JSONEncoder.dc.encode(layout),
           existing == encoded {
            return
        }
        try? layout.save(to: url)
        invalidatePresetCache()
    }

    public static func loadLastUsedPreset() -> CanvasLayout? {
        try? CanvasLayout.load(from: lastUsedPresetURL())
    }
}