import SwiftUI
import DesktopCanvas
import AVFoundation

final class EditorState: ObservableObject {
    @Published var canvases: [CanvasModel] = []
    @Published var selectedCanvasID: UUID?
    @Published var isApplied: Bool = false
    @Published var statusMessage: String = ""
    @Published var statusType: StatusType = .info

    @Published var snapEnabled: Bool = true
    @Published var layoutGridSize: CGFloat = 50
    @Published var snapToScreenEdges: Bool = true
    @Published var snapToCanvasEdges: Bool = true
    @Published var margin: CGFloat = 0
    @Published var backgroundColor: CodableColor? = nil

    @Published var showPresetManager: Bool = false

    @Published var showGridEditor: Bool = false
    @Published var gridEditorCanvasID: UUID?

    var presetInfos: [PresetInfo] {
        DesktopCanvas.shared.listPresetsWithMetadata()
    }

    enum StatusType {
        case info
        case warning
        case error
    }

    var selectedCanvas: CanvasModel? {
        guard let id = selectedCanvasID else { return nil }
        return canvases.first { $0.id == id }
    }

    func addGameOfLifeCanvas() {
        let frame = nextDefaultFrame()
        let config = GameOfLifeConfig.default
        let canvas = CanvasModel(
            type: .gameOfLife,
            frame: frame,
            gameOfLifeConfig: config,
            videoConfig: nil
        )
        canvases.append(canvas)
        selectedCanvasID = canvas.id
    }

    func addVideoCanvas() {
        let frame = nextDefaultFrame()
        let config = VideoConfig.default
        let canvas = CanvasModel(
            type: .video,
            frame: frame,
            gameOfLifeConfig: nil,
            videoConfig: config
        )
        canvases.append(canvas)
        selectedCanvasID = canvas.id
    }

    func switchCanvasType(to newType: CanvasType) {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id }),
              canvases[index].type != newType
        else { return }

        var canvas = canvases[index]
        canvas.type = newType
        if newType == .gameOfLife {
            canvas.gameOfLifeConfig = GameOfLifeConfig.default
            canvas.videoConfig = nil
        } else {
            canvas.videoConfig = VideoConfig.default
            canvas.gameOfLifeConfig = nil
        }
        canvases[index] = canvas
        autoApplyIfNeeded()
    }

    func updateSelectedGoLConfig(_ config: GameOfLifeConfig) {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id })
        else { return }
        canvases[index].gameOfLifeConfig = config
        autoApplyIfNeeded()
    }

    func updateSelectedVideoConfig(_ config: VideoConfig) {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id })
        else { return }
        canvases[index].videoConfig = config
        autoApplyIfNeeded()
    }

    func setPaused(_ paused: Bool, for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }),
              var config = canvases[index].gameOfLifeConfig
        else { return }
        config.paused = paused
        canvases[index].gameOfLifeConfig = config

        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            paused ? provider.pause() : provider.resume()
        }
    }

    func persistGridState(_ gridState: [[Bool]], canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }),
              var config = canvases[index].gameOfLifeConfig
        else { return }
        config.gridState = gridState
        canvases[index].gameOfLifeConfig = config
    }

    private func syncGridStatesFromProviders(always: Bool = false) {
        for i in 0..<canvases.count {
            guard canvases[i].type == .gameOfLife else { continue }
            let canvasID = canvases[i].id
            DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
                let w = provider.gridWidth
                let h = provider.gridHeight

                if !always,
                   let existing = canvases[i].gameOfLifeConfig?.gridState,
                   existing.count == h, existing.first?.count == w {
                    return
                }

                let snapshot = provider.gridSnapshot()
                var gridState: [[Bool]] = []
                gridState.reserveCapacity(h)
                for row in 0..<h {
                    let base = row * w
                    let rowData = snapshot[base..<base + w].map { $0 != 0 }
                    gridState.append(rowData)
                }
                canvases[i].gameOfLifeConfig?.gridState = gridState
            }
        }
    }

    func randomSeed(by canvasID: UUID, density: Double) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }),
              var config = canvases[index].gameOfLifeConfig
        else { return }
        config.gridState = nil
        canvases[index].gameOfLifeConfig = config

        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.randomSeed(density: density)
        }
    }

    func clearAll(by canvasID: UUID) {
        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.clearAll()
        }
    }

    func updateSelectedFrame(_ frame: CGRect) {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id })
        else { return }
        canvases[index].frame = frame
        autoApplyIfNeeded()
    }

    func removeSelectedCanvas() {
        guard let id = selectedCanvasID else { return }
        canvases.removeAll { $0.id == id }
        if selectedCanvasID == id {
            selectedCanvasID = nil
        }
        autoApplyIfNeeded()
    }

    func moveCanvas(from source: IndexSet, to destination: Int) {
        canvases.move(fromOffsets: source, toOffset: destination)
        autoApplyIfNeeded()
    }

    func fillScreen() {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id }),
              let screen = screenForCanvas(canvases[index]) ?? NSScreen.main
        else { return }

        let fullFrame = screen.frame
        let canvas = canvases[index]

        switch canvas.type {
        case .video:
            if let naturalSize = canvas.videoConfig?.naturalSize,
               naturalSize.width > 0, naturalSize.height > 0 {
                let videoRatio = naturalSize.width / naturalSize.height
                let screenRatio = fullFrame.width / fullFrame.height
                var fillFrame = fullFrame
                if videoRatio > screenRatio {
                    fillFrame.size.width = fullFrame.height * videoRatio
                    fillFrame.origin.x = fullFrame.midX - fillFrame.width / 2
                } else {
                    fillFrame.size.height = fullFrame.width / videoRatio
                    fillFrame.origin.y = fullFrame.midY - fillFrame.height / 2
                }
                canvases[index].frame = fillFrame
            } else {
                canvases[index].frame = fullFrame
            }

        case .gameOfLife:
            var frame = fullFrame
            if let config = canvas.gameOfLifeConfig {
                // `cellSize` is clamped to ≥ 2 by `GameOfLifeConfig`, so the
                // divisions below cannot divide by zero on a corrupt preset.
                let cellSize = CGFloat(config.cellSize)
                let snappedW = floor(frame.width / cellSize) * cellSize
                let snappedH = floor(frame.height / cellSize) * cellSize
                frame.size = CGSize(width: snappedW, height: snappedH)
                frame.origin.x = fullFrame.midX - snappedW / 2
                frame.origin.y = fullFrame.midY - snappedH / 2
            }
            canvases[index].frame = frame
        }

        setStatus("Filled screen: \(Int(canvases[index].frame.width))×\(Int(canvases[index].frame.height))", type: .info)
        autoApplyIfNeeded()
    }

    func centerCanvas() {
        guard let id = selectedCanvasID,
              let index = canvases.firstIndex(where: { $0.id == id }),
              let screen = screenForCanvas(canvases[index]) ?? NSScreen.main
        else { return }

        let size = canvases[index].frame.size
        canvases[index].frame.origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        setStatus("Centered on screen", type: .info)
        autoApplyIfNeeded()
    }

    func applyToDesktop() {
        syncGridStatesFromProviders(always: true)

        let layout = CanvasLayout(name: "Current", canvases: canvases, backgroundColor: backgroundColor)
        let result = DesktopCanvas.shared.apply(layout: layout)

        syncGridStatesFromProviders()

        switch result {
        case .ok:
            isApplied = true
            setStatus("Applied — \(canvases.count) canvas(es) on desktop", type: .info)
        case .warning(let message):
            isApplied = true
            setStatus("⚠️ \(message)", type: .warning)
        case .error(let message):
            isApplied = false
            setStatus("❌ \(message)", type: .error)
        }
    }

    func stopDesktop() {
        DesktopCanvas.shared.stop()
        isApplied = false
        setStatus("Stopped", type: .info)
    }

    /// Re-frames the already-running desktop canvases after an edit.
    ///
    /// Unlike `applyToDesktop()` this keeps the existing windows, providers and
    /// video players alive, so it is what drag/resize commits use. The layout it
    /// builds carries `backgroundColor`, and the result is surfaced to the user
    /// instead of being dropped.
    func refreshDesktop() {
        let layout = CanvasLayout(name: "Current", canvases: canvases, backgroundColor: backgroundColor)
        let overlaps = OverlapResolver.detectOverlaps(in: canvases)
        if let first = overlaps.first {
            let names = canvases.filter { $0.id == first.0 || $0.id == first.1 }
                .enumerated()
                .map { "\($0.element.type == .video ? "Video" : "Game of Life") \($0.offset + 1)" }
            let suffix = overlaps.count > 1 ? " (and \(overlaps.count - 1) more)" : ""
            setStatus("⚠️ \(names.joined(separator: " overlaps "))\(suffix)", type: .warning)
        }
        DesktopCanvas.shared.refresh(with: layout)
        isApplied = true
    }

    private var applyWorkItem: DispatchWorkItem?

    func autoApplyIfNeeded() {
        guard isApplied else { return }
        applyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let layout = CanvasLayout(name: "Current", canvases: self.canvases, backgroundColor: self.backgroundColor)
            DesktopCanvas.shared.refresh(with: layout)
            self.syncGridStatesFromProviders()
        }
        applyWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    func loadLastSession() {
        guard let layout = DesktopCanvas.loadLastUsedPreset() else { return }
        canvases = layout.canvases
        setStatus("Loaded last session: \(layout.canvases.count) canvas(es)", type: .info)
    }

    private func nextDefaultFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 100, y: 100, width: 400, height: 300)
        }
        let size = CGSize(width: 400, height: 300)
        let columns = 3
        let spacing: CGFloat = 20
        let col = canvases.count % columns
        let row = canvases.count / columns
        let origin = CGPoint(
            x: screen.frame.midX - size.width * CGFloat(columns) / 2
                - spacing * CGFloat(columns - 1) / 2
                + CGFloat(col) * (size.width + spacing),
            y: screen.frame.midY + size.height / 2 + spacing
                - CGFloat(row) * (size.height + spacing)
        )
        return CGRect(origin: origin, size: size)
    }

    private func screenForCanvas(_ canvas: CanvasModel) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(canvas.frame) }
    }

    private func setStatus(_ message: String, type: StatusType) {
        statusMessage = message
        statusType = type
    }

    func mutateCanvas(at index: Int, mutation: (inout CanvasModel) -> Void) {
        guard index < canvases.count else { return }
        mutation(&canvases[index])
        autoApplyIfNeeded()
    }

    func mutateCanvas(by id: UUID, mutation: (inout CanvasModel) -> Void) {
        guard let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        mutateCanvas(at: index, mutation: mutation)
    }

    func mutateGoLConfig(at index: Int, mutation: (inout GameOfLifeConfig) -> Void) {
        guard index < canvases.count,
              var config = canvases[index].gameOfLifeConfig
        else { return }
        mutation(&config)
        canvases[index].gameOfLifeConfig = config
        autoApplyIfNeeded()
    }

    func mutateGoLConfig(by id: UUID, mutation: (inout GameOfLifeConfig) -> Void) {
        guard let index = canvases.firstIndex(where: { $0.id == id }),
              index < canvases.count,
              var config = canvases[index].gameOfLifeConfig
        else { return }
        mutation(&config)
        canvases[index].gameOfLifeConfig = config
        autoApplyIfNeeded()
    }

    func mutateVideoConfig(at index: Int, mutation: (inout VideoConfig) -> Void) {
        guard index < canvases.count,
              var config = canvases[index].videoConfig
        else { return }
        mutation(&config)
        canvases[index].videoConfig = config
        autoApplyIfNeeded()
    }

    func mutateVideoConfig(by id: UUID, mutation: (inout VideoConfig) -> Void) {
        guard let index = canvases.firstIndex(where: { $0.id == id }),
              index < canvases.count,
              var config = canvases[index].videoConfig
        else { return }
        mutation(&config)
        canvases[index].videoConfig = config
        autoApplyIfNeeded()
    }

    func setVideoURL(_ url: URL, for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }),
              index < canvases.count
        else { return }

        canvases[index].videoConfig?.videoURL = url

        let asset = AVAsset(url: url)
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, _ in
            guard let self, let track = tracks?.first else {
                DispatchQueue.main.async {
                    guard let idx = self?.canvases.firstIndex(where: { $0.id == canvasID }) else { return }
                    self?.canvases[idx].videoConfig?.naturalSize = nil
                    self?.autoApplyIfNeeded()
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self,
                      let idx = self.canvases.firstIndex(where: { $0.id == canvasID })
                else { return }

                do {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let rawSize = size.applying(transform)
                    let naturalSize = CGSize(
                        width: abs(rawSize.width),
                        height: abs(rawSize.height)
                    )

                    self.canvases[idx].videoConfig?.naturalSize = naturalSize

                    if naturalSize.width > 0, naturalSize.height > 0 {
                        let ratio = naturalSize.width / naturalSize.height
                        var newFrame = self.canvases[idx].frame
                        newFrame.size.height = newFrame.width / ratio
                        self.canvases[idx].frame = newFrame
                    }
                } catch {
                    self.canvases[idx].videoConfig?.naturalSize = nil
                }

                self.autoApplyIfNeeded()
            }
        }
    }

    func presetExists(named name: String) -> Bool {
        let url = DesktopCanvas.presetsDirectory().appendingPathComponent("\(name).json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    func saveCurrentPreset(named name: String) {
        guard !name.isEmpty else {
            setStatus("Please enter a preset name", type: .warning)
            return
        }
        let dir = DesktopCanvas.presetsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let layout = CanvasLayout(name: name, canvases: canvases, backgroundColor: backgroundColor)
        do {
            try DesktopCanvas.shared.savePreset(layout, named: name)
            setStatus("Saved preset: \"\(name)\"", type: .info)
        } catch {
            setStatus("Failed to save preset: \(error.localizedDescription)", type: .error)
        }
    }

    func loadPreset(named name: String) {
        do {
            let layout = try DesktopCanvas.shared.loadPreset(named: name)
            canvases = layout.canvases
            selectedCanvasID = nil
            setStatus("Loaded preset: \"\(name)\" (\(layout.canvases.count) canvas(es))", type: .info)
            autoApplyIfNeeded()
        } catch {
            setStatus("Failed to load preset: \(error.localizedDescription)", type: .error)
        }
    }

    func deletePreset(named name: String) {
        do {
            try DesktopCanvas.shared.deletePreset(named: name)
            setStatus("Deleted preset: \"\(name)\"", type: .info)
        } catch {
            setStatus("Failed to delete preset: \(error.localizedDescription)", type: .error)
        }
    }
}