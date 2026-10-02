import SwiftUI
import DesktopCanvas
import UniformTypeIdentifiers

struct CanvasSettingsView: View {
    @ObservedObject var state: EditorState

    @State private var cellSizeSliderValue: Double = 8
    @State private var speedSliderValue: Double = 30
    @State private var volumeSliderValue: Double = 0

    var body: some View {
        Group {
            if let id = state.selectedCanvasID,
               let canvas = state.canvases.first(where: { $0.id == id }) {
                settingsContent(canvasID: canvas.id, canvas: canvas)
            }
        }
        .onChange(of: state.selectedCanvasID) { newID in
            if let id = newID,
               let config = state.canvases.first(where: { $0.id == id })?.gameOfLifeConfig {
                cellSizeSliderValue = Double(config.cellSize)
                speedSliderValue = config.generationsPerSecond
            }
            if let id = newID,
               let config = state.canvases.first(where: { $0.id == id })?.videoConfig {
                volumeSliderValue = config.volume
            }
        }
    }

    @ViewBuilder
    private func settingsContent(canvasID: UUID, canvas: CanvasModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                typeSection(canvasID: canvasID, canvas: canvas)
                Divider().padding(.vertical, 8)
                positionSizeSection(canvasID: canvasID, canvas: canvas)
                Divider().padding(.vertical, 8)

                switch canvas.type {
                case .gameOfLife:
                    gameOfLifeSection(canvasID: canvasID, canvas: canvas)
                case .video:
                    videoSection(canvasID: canvasID, canvas: canvas)
                }

                Divider().padding(.vertical, 8)
                dangerSection
            }
            .padding(12)
        }
    }

    // MARK: - Type

    private func typeSection(canvasID: UUID, canvas: CanvasModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type").font(.headline)

            Picker("Canvas Type", selection: Binding(
                get: { canvas.type },
                set: { state.switchCanvasType(to: $0) }
            )) {
                Text("Game of Life").tag(CanvasType.gameOfLife)
                Text("Video").tag(CanvasType.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Position & Size

    private func positionSizeSection(canvasID: UUID, canvas: CanvasModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position & Size").font(.headline)

            HStack(spacing: 8) {
                labeledField("X", value: canvas.frame.origin.x) { newX in
                    state.mutateCanvas(by: canvasID) { $0.frame.origin.x = newX }
                }
                labeledField("Y", value: canvas.frame.origin.y) { newY in
                    state.mutateCanvas(by: canvasID) { $0.frame.origin.y = newY }
                }
            }

            HStack(spacing: 8) {
                labeledField("W", value: canvas.frame.width) { newW in
                    let clampedW = max(32, newW)
                    state.mutateCanvas(by: canvasID) { canvas in
                        canvas.frame.size.width = clampedW
                        if let ratio = aspectRatio(for: canvas) {
                            canvas.frame.size.height = clampedW / ratio
                        }
                    }
                }
                labeledField("H", value: canvas.frame.height) { newH in
                    let clampedH = max(32, newH)
                    state.mutateCanvas(by: canvasID) { canvas in
                        canvas.frame.size.height = clampedH
                        if let ratio = aspectRatio(for: canvas) {
                            canvas.frame.size.width = clampedH * ratio
                        }
                    }
                }
            }
        }
    }

    private func aspectRatio(for canvas: CanvasModel) -> CGFloat? {
        guard canvas.type == .video,
              let size = canvas.videoConfig?.naturalSize,
              size.width > 0, size.height > 0
        else { return nil }
        return size.width / size.height
    }

    /// - Parameter onChange: receives the value verbatim. Callers clamp what
    ///   needs clamping, because canvas origins are legitimately negative on a
    ///   multi-display desktop.
    private func labeledField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), formatter: NumberFormatter.integer)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
        }
    }

    // MARK: - Game of Life

    private func gameOfLifeSection(canvasID: UUID, canvas: CanvasModel) -> some View {
        guard canvas.gameOfLifeConfig != nil else {
            return AnyView(Text("No Game of Life config").foregroundColor(.secondary))
        }

        return AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("Game of Life").font(.headline)

            cellSizeControl(canvasID: canvasID)
            speedControl(canvasID: canvasID)
            colorControls(canvasID: canvasID)
            ruleSetControl(canvasID: canvasID)
            seedClearButtons(canvasID: canvasID, canvas: canvas)
            pauseToggle(canvasID: canvasID)
        })
    }

    private func cellSizeControl(canvasID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cell Size: \(Int(cellSizeSliderValue)) pt").font(.caption)
            Slider(value: $cellSizeSliderValue, in: 2...64, step: 1) { editing in
                if !editing {
                    state.mutateGoLConfig(by: canvasID) { $0.cellSize = Int(cellSizeSliderValue) }
                }
            }
        }
    }

    private func speedControl(canvasID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speed: \(Int(speedSliderValue)) gen/s").font(.caption)
            Slider(value: $speedSliderValue, in: 1...60, step: 1) { editing in
                if !editing {
                    state.mutateGoLConfig(by: canvasID) { $0.generationsPerSecond = speedSliderValue }
                }
            }
        }
    }

    private func colorControls(canvasID: UUID) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alive").font(.caption)
                NativeColorWell(codableColor: Binding(
                    get: { golConfig(by: canvasID).aliveColor },
                    set: { newValue in
                        state.mutateGoLConfig(by: canvasID) { $0.aliveColor = newValue }
                    }
                ))
                .frame(width: 44, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Dead").font(.caption)
                NativeColorWell(codableColor: Binding(
                    get: { golConfig(by: canvasID).deadColor },
                    set: { newValue in
                        state.mutateGoLConfig(by: canvasID) { $0.deadColor = newValue }
                    }
                ))
                .frame(width: 44, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Margin").font(.caption)
                NativeColorWell(codableColor: Binding(
                    get: { golConfig(by: canvasID).marginColor },
                    set: { newValue in
                        state.mutateGoLConfig(by: canvasID) { $0.marginColor = newValue }
                    }
                ))
                .frame(width: 44, height: 24)
            }
        }
    }

    private func ruleSetControl(canvasID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rule Set").font(.caption)
            Picker("", selection: Binding(
                get: { golConfig(by: canvasID).ruleSet },
                set: { newValue in
                    state.mutateGoLConfig(by: canvasID) { $0.ruleSet = newValue }
                }
            )) {
                ForEach(RuleSet.presets, id: \.self) { rule in
                    Text(rule.name).tag(rule)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private func seedClearButtons(canvasID: UUID, canvas: CanvasModel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Random Seed") {
                    state.randomSeed(by: canvasID, density: 0.5)
                }
                Button("Clear") {
                    state.clearAll(by: canvasID)
                }
            }
            Button("Edit Grid") {
                state.gridEditorCanvasID = canvasID
                state.showGridEditor = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func pauseToggle(canvasID: UUID) -> some View {
        Toggle("Paused", isOn: Binding(
            get: { golConfig(by: canvasID).paused },
            set: { newValue in
                state.setPaused(newValue, for: canvasID)
            }
        ))
    }

    // MARK: - Video

    private func videoSection(canvasID: UUID, canvas: CanvasModel) -> some View {
        guard canvas.videoConfig != nil else {
            return AnyView(Text("No Video config").foregroundColor(.secondary))
        }

        return AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("Video").font(.headline)

            videoFilePicker(canvasID: canvasID)
            volumeControl(canvasID: canvasID)
            loopToggle(canvasID: canvasID)
        })
    }

    private func videoFilePicker(canvasID: UUID) -> some View {
        let url = videoConfig(by: canvasID).videoURL
        return HStack {
            Text(url.path.isEmpty ? "No video selected" : url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Choose...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.begin { response in
                    if response == .OK, let selectedURL = panel.url {
                        state.setVideoURL(selectedURL, for: canvasID)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func volumeControl(canvasID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Volume: \(Int(volumeSliderValue * 100))%").font(.caption)
            Slider(value: $volumeSliderValue, in: 0...1) { editing in
                if !editing {
                    state.mutateVideoConfig(by: canvasID) { $0.volume = volumeSliderValue }
                }
            }
        }
    }

    private func loopToggle(canvasID: UUID) -> some View {
        Toggle("Loop", isOn: Binding(
            get: { videoConfig(by: canvasID).loop },
            set: { newValue in
                state.mutateVideoConfig(by: canvasID) { $0.loop = newValue }
            }
        ))
    }

    // MARK: - Danger

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive, action: state.removeSelectedCanvas) {
                Label("Remove Canvas", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Helpers

    private func golConfig(by id: UUID) -> GameOfLifeConfig {
        state.canvases.first(where: { $0.id == id })?.gameOfLifeConfig ?? .default
    }

    private func videoConfig(by id: UUID) -> VideoConfig {
        state.canvases.first(where: { $0.id == id })?.videoConfig ?? .default
    }
}

extension NumberFormatter {
    static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = true
        f.minimum = 0
        return f
    }()
}