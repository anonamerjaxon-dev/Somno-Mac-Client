import SwiftUI
import DesktopCanvas

enum DrawTool: String, CaseIterable {
    case pencil
    case line
    case rectangle
    case eraser

    var iconName: String {
        switch self {
        case .pencil: return "pencil"
        case .line: return "pencil.line"
        case .rectangle: return "rectangle"
        case .eraser: return "eraser"
        }
    }

    var label: String {
        switch self {
        case .pencil: return "Pencil"
        case .line: return "Line"
        case .rectangle: return "Rect"
        case .eraser: return "Eraser"
        }
    }
}

struct Pattern: Identifiable {
    let id = UUID()
    let name: String
    let cells: [(row: Int, col: Int)]

    static let gliderUp = Pattern(name: "Glider \u{2191}", cells: [
        (0,1), (1,2), (2,0), (2,1), (2,2)
    ])
    static let gliderRight = Pattern(name: "Glider \u{2192}", cells: [
        (0,0), (1,0), (1,2), (2,0), (2,1)
    ])
    static let gliderDown = Pattern(name: "Glider \u{2193}", cells: [
        (0,0), (0,1), (0,2), (1,2), (2,1)
    ])
    static let gliderLeft = Pattern(name: "Glider \u{2190}", cells: [
        (0,1), (1,0), (1,2), (2,0), (2,1)
    ])
    static let blinkerH = Pattern(name: "Blinker \u{2014}", cells: [
        (0,0), (0,1), (0,2)
    ])
    static let blinkerV = Pattern(name: "Blinker |", cells: [
        (0,0), (1,0), (2,0)
    ])
    static let block = Pattern(name: "Block", cells: [
        (0,0), (0,1), (1,0), (1,1)
    ])
    static let beehive = Pattern(name: "Beehive", cells: [
        (0,1),(0,2),(1,0),(1,3),(2,1),(2,2)
    ])
    static let boat = Pattern(name: "Boat", cells: [
        (0,0),(0,1),(1,0),(1,2),(2,1)
    ])
    static let loaf = Pattern(name: "Loaf", cells: [
        (0,1),(0,2),(1,0),(1,3),(2,1),(2,3),(3,2)
    ])
    static let lwssUp = Pattern(name: "LWSS \u{2191}", cells: [
        (0,1),(0,4),(1,0),(2,0),(2,4),(3,0),(3,1),(3,2),(3,3)
    ])
    static let lwssRight = Pattern(name: "LWSS \u{2192}", cells: [
        (0,2),(0,3),(0,4),(1,0),(1,4),(2,4),(3,0),(3,3)
    ])
    static let lwssDown = Pattern(name: "LWSS \u{2193}", cells: [
        (0,0),(0,1),(0,2),(0,3),(1,0),(1,4),(2,4),(3,1),(3,4)
    ])
    static let lwssLeft = Pattern(name: "LWSS \u{2190}", cells: [
        (0,2),(1,0),(1,3),(2,0),(3,0),(3,1),(3,2),(3,3)
    ])
    static let pulsar = Pattern(name: "Pulsar", cells: [
        (0,2),(0,3),(0,4),(0,8),(0,9),(0,10),
        (2,0),(2,5),(2,7),(2,12),(3,0),(3,5),(3,7),(3,12),
        (4,0),(4,5),(4,7),(4,12),(5,2),(5,3),(5,4),(5,8),(5,9),(5,10),
        (7,2),(7,3),(7,4),(7,8),(7,9),(7,10),
        (8,0),(8,5),(8,7),(8,12),(9,0),(9,5),(9,7),(9,12),
        (10,0),(10,5),(10,7),(10,12),
        (12,2),(12,3),(12,4),(12,8),(12,9),(12,10)
    ])
    static let gosperGun = Pattern(name: "Gosper Gun", cells: [
        (0,24),(1,22),(1,24),(2,12),(2,13),(2,20),(2,21),(2,34),(2,35),
        (3,11),(3,15),(3,20),(3,21),(3,34),(3,35),(4,0),(4,1),(4,10),
        (4,16),(4,20),(4,21),(5,0),(5,1),(5,10),(5,14),(5,16),(5,17),
        (5,22),(5,24),(6,10),(6,16),(6,24),(7,11),(7,15),(8,12),(8,13)
    ])

    static let allPatterns: [Pattern] = [
        gliderUp, gliderRight, gliderDown, gliderLeft,
        blinkerH, blinkerV,
        block, beehive, boat, loaf,
        lwssUp, lwssRight, lwssDown, lwssLeft,
        pulsar, gosperGun
    ]
}

extension Pattern: Equatable {
    /// Identity by content: `id` is a fresh UUID per instance, so two views
    /// holding the same pattern would otherwise always compare unequal.
    static func == (lhs: Pattern, rhs: Pattern) -> Bool {
        lhs.name == rhs.name
            && lhs.cells.count == rhs.cells.count
            && zip(lhs.cells, rhs.cells).allSatisfy { $0.row == $1.row && $0.col == $1.col }
    }

    /// True when two optionals hold the same pattern; `nil` matches only `nil`.
    static func equivalent(_ lhs: Pattern?, _ rhs: Pattern?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return false
        }
    }
}

extension Pattern {
    func rotated(by turns: Int) -> [(row: Int, col: Int)] {
        let r = ((turns % 4) + 4) % 4
        if r == 0 { return cells }
        let maxR = cells.map(\.row).max() ?? 0
        let maxC = cells.map(\.col).max() ?? 0
        switch r {
        case 1: return cells.map { (row: $0.col, col: maxR - $0.row) }
        case 2: return cells.map { (row: maxR - $0.row, col: maxC - $0.col) }
        case 3: return cells.map { (row: maxC - $0.col, col: $0.row) }
        default: return cells
        }
    }
}

struct GridEditorView: View {
    let canvasID: UUID
    @ObservedObject var state: EditorState

    @State private var selectedTool: DrawTool = .pencil
    @State private var selectedPattern: Pattern?
    @State private var showGridLines = true
    @State private var density: Double = 0.5
    @State private var grid: [UInt8] = []
    @State private var gridW: Int = 0
    @State private var gridH: Int = 0
    @State private var cellSize: Int = 8
    @State private var aliveColor: NSColor = .green
    @State private var deadColor: NSColor = NSColor(white: 0.05, alpha: 1)
    @State private var hoveredCell: (row: Int, col: Int)?
    @State private var shapePreview: (r0: Int, c0: Int, r1: Int, c1: Int)?
    @State private var displayZoom: CGFloat = 8
    @State private var gridViewRef: GridCanvasNSView?
    @State private var patternRotation: Int = 0
    @State private var isPlaying = false
    @State private var keyEventMonitor: Any?

    @Environment(\.dismiss) private var dismiss

    private var canvas: CanvasModel? {
        state.canvases.first(where: { $0.id == canvasID })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            gridCanvas
            Divider()
            statusBar
        }
        .frame(minWidth: 1000, idealWidth: 1400, minHeight: 700, idealHeight: 1000)
        .onAppear {
            loadGridState()
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Typing in a text field must never be reinterpreted as a tool
                // shortcut, so the editor yields while one has focus.
                guard !isTextInputFocused else { return event }

                switch event.keyCode {
                case 49:
                    DispatchQueue.main.async {
                        patternRotation = (patternRotation + 1) % 4
                    }
                    return nil
                case 35:
                    DispatchQueue.main.async { selectedTool = .pencil; selectedPattern = nil }
                    return nil
                case 37:
                    DispatchQueue.main.async { selectedTool = .line; selectedPattern = nil }
                    return nil
                case 15:
                    DispatchQueue.main.async { selectedTool = .rectangle; selectedPattern = nil }
                    return nil
                case 14:
                    DispatchQueue.main.async { selectedTool = .eraser; selectedPattern = nil }
                    return nil
                case 5:
                    DispatchQueue.main.async { showGridLines.toggle() }
                    return nil
                default:
                    break
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            flushAndResume()
        }
        .onExitCommand(perform: { dismiss() })
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(DrawTool.allCases, id: \.self) { tool in
                Button(action: {
                    selectedTool = tool
                    if tool != .pencil { selectedPattern = nil }
                }) {
                    Image(systemName: tool.iconName)
                }
                .buttonStyle(.bordered)
                .tint(selectedTool == tool ? .accentColor : nil)
                .opacity(selectedTool == tool ? 1.0 : 0.5)
                .help(tool.label)
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Menu {
                ForEach(Pattern.allPatterns) { pattern in
                    Button(pattern.name) {
                        selectedPattern = pattern
                        selectedTool = .pencil
                    }
                }
                Divider()
                Button("None") {
                    selectedPattern = nil
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.grid.3x3")
                    Text(selectedPattern?.name ?? "Pattern")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: 110)

            if selectedPattern != nil {
                Button(action: { patternRotation = (patternRotation + 1) % 4 }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .help("Rotate pattern (Space)")

                Text(rotationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 28)
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Button(action: { gridViewRef?.adjustZoom(0.5) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom Out")

            Text("\(Int(displayZoom * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 32)

            Button(action: { gridViewRef?.adjustZoom(2.0) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom In")

            Button(action: { gridViewRef?.resetView() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .help("Fit to view")

            Toggle(isOn: $showGridLines) {
                Image(systemName: "grid")
            }
            .toggleStyle(.button)
            .help("Toggle grid lines (G)")

            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .help(isPlaying ? "Pause simulation" : "Run simulation")

            Spacer()

            Slider(value: $density, in: 0.1...0.9, step: 0.05)
                .frame(width: 60)

            Button("Random") {
                randomSeed()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Clear") {
                clearAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var rotationLabel: String {
        switch patternRotation % 4 {
        case 0: return "0°"
        case 1: return "90°"
        case 2: return "180°"
        case 3: return "270°"
        default: return ""
        }
    }

    private var gridCanvas: some View {
        GridCanvasView(
            grid: $grid,
            gridW: gridW,
            gridH: gridH,
            cellSize: cellSize,
            initialZoom: displayZoom,
            showGridLines: showGridLines,
            aliveColor: aliveColor,
            deadColor: deadColor,
            selectedTool: selectedTool,
            selectedPattern: selectedPattern,
            patternRotation: patternRotation,
            hoveredCell: $hoveredCell,
            shapePreview: $shapePreview,
            onZoomChange: { displayZoom = $0 },
            onViewReady: { gridViewRef = $0 },
            onGridChanged: { newGrid in
                grid = newGrid
                flushToProvider()
            },
            onShapeComplete: { _, _, _, _, _ in
                // The shape has already been drawn into the local grid by the
                // NSView. Pushing it to the live provider is just a flush, so
                // there is one code path for every tool rather than a second,
                // duplicated copy of the line/rectangle geometry.
                flushToProvider()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("\(gridW)\u{00D7}\(gridH) cells")
                .font(.caption)
                .foregroundColor(.secondary)

            if let hover = hoveredCell {
                Text("Cursor: (\(hover.col), \(hover.row))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Scroll to zoom  \u{2022}  Right-drag to pan  \u{2022}  Pencil(P)\u{21C3}Line(L)\u{21C3}Rect(R)\u{21C3}Eraser(E)\u{21C3}Grid(G)")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadGridState() {
        isPlaying = !(canvas?.gameOfLifeConfig?.paused ?? false)

        if let config = canvas?.gameOfLifeConfig {
            cellSize = config.cellSize
            aliveColor = config.aliveColor.nsColor
            deadColor = config.deadColor.nsColor
        }

        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.pause()

            let w = provider.gridWidth
            let h = provider.gridHeight
            let snapshot = provider.gridSnapshot()

            DispatchQueue.main.async {
                if w > 0, h > 0 {
                    self.gridW = w
                    self.gridH = h
                    self.grid = snapshot
                }
            }
        }

        if gridW == 0 || gridH == 0, let canvas = canvas {
            let dims = GameOfLifeConfig.gridDimensions(for: canvas.frame, cellSize: cellSize)
            gridW = dims.cols
            gridH = dims.rows
            grid = Array(repeating: 0, count: gridW * gridH)
        }
    }

    private func togglePlayPause() {
        if isPlaying {
            DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
                provider.pause()
            }
            isPlaying = false
        } else {
            flushToProvider()
            DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
                provider.resume()
            }
            isPlaying = true
        }
    }

    /// True while an editable text control owns first responder in the key window,
    /// which is where typing has to go verbatim.
    ///
    /// Checked at key-down time rather than stored, because focus moves inside
    /// SwiftUI without the grid editor being told about it.
    private var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        return responder is NSTextField
    }

    private func flushToProvider() {
        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.writeFullGrid(grid)
        }
    }

    private func flushAndResume() {
        let gridCopy = grid
        let w = gridW
        let h = gridH
        let cID = canvasID
        // The editor pauses the simulation on open, so it owns restoring the run
        // state when it closes. It must restore exactly what it found: a canvas
        // the user had paused must stay paused on the desktop.
        let wasPlaying = isPlaying

        DesktopCanvas.shared.withGoLProvider(for: cID) { provider in
            provider.writeFullGrid(gridCopy)
            if wasPlaying {
                provider.resume()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var gridState: [[Bool]] = []
            gridState.reserveCapacity(h)
            for row in 0..<h {
                let offset = row * w
                let end = min(offset + w, gridCopy.count)
                gridState.append(gridCopy[offset..<end].map { $0 != 0 })
            }
            DispatchQueue.main.async {
                self.state.persistGridState(gridState, canvasID: cID)
            }
        }
    }

    private func randomSeed() {
        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.randomSeed(density: density)
        }
        refreshGridFromProvider()
    }

    private func clearAll() {
        grid = Array(repeating: 0, count: gridW * gridH)
        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            provider.clearAll()
        }
    }

    private func refreshGridFromProvider() {
        DesktopCanvas.shared.withGoLProvider(for: canvasID) { provider in
            let snapshot = provider.gridSnapshot()
            DispatchQueue.main.async {
                if snapshot.count == self.gridW * self.gridH {
                    self.grid = snapshot
                }
            }
        }
    }
}

struct GridCanvasView: NSViewRepresentable {
    @Binding var grid: [UInt8]
    let gridW: Int
    let gridH: Int
    let cellSize: Int
    var initialZoom: CGFloat
    let showGridLines: Bool
    let aliveColor: NSColor
    let deadColor: NSColor
    let selectedTool: DrawTool
    let selectedPattern: Pattern?
    let patternRotation: Int
    @Binding var hoveredCell: (row: Int, col: Int)?
    @Binding var shapePreview: (r0: Int, c0: Int, r1: Int, c1: Int)?
    var onZoomChange: (CGFloat) -> Void
    var onViewReady: (GridCanvasNSView) -> Void
    var onGridChanged: ([UInt8]) -> Void
    var onCellAction: ((Int, Int, DrawTool) -> Void)?
    var onShapeComplete: (Int, Int, Int, Int, DrawTool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onShapeComplete: onShapeComplete,
            onGridChanged: onGridChanged
        )
    }

    func makeNSView(context: Context) -> GridCanvasNSView {
        let view = GridCanvasNSView()
        view.coordinator = context.coordinator
        view.onZoomChange = onZoomChange
        view.initialZoom = initialZoom
        DispatchQueue.main.async { onViewReady(view) }
        return view
    }

    func updateNSView(_ nsView: GridCanvasNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.coordinator?.onShapeComplete = onShapeComplete
        nsView.coordinator?.onGridChanged = onGridChanged
        nsView.onZoomChange = onZoomChange
        nsView.onHoverChange = { hoveredCell = $0 }
        nsView.onShapePreviewChange = { shapePreview = $0 }
        // Assigning the grid bumps `gridGeneration`, which invalidates the cached
        // bitmap. Everything else is compared first so that an unrelated SwiftUI
        // update — a hover, a tool switch, a status-bar string — does not throw
        // away a bitmap that is still correct.
        nsView.apply(
            grid: grid,
            gridW: gridW,
            gridH: gridH,
            cellSize: cellSize,
            showGridLines: showGridLines,
            aliveColor: aliveColor,
            deadColor: deadColor,
            selectedTool: selectedTool,
            selectedPattern: selectedPattern,
            patternRotation: patternRotation
        )
    }

    final class Coordinator {
        var onShapeComplete: (Int, Int, Int, Int, DrawTool) -> Void
        var onGridChanged: ([UInt8]) -> Void

        init(
            onShapeComplete: @escaping (Int, Int, Int, Int, DrawTool) -> Void,
            onGridChanged: @escaping ([UInt8]) -> Void
        ) {
            self.onShapeComplete = onShapeComplete
            self.onGridChanged = onGridChanged
        }
    }
}

final class GridCanvasNSView: NSView {
    override var isFlipped: Bool { true }

    var coordinator: GridCanvasView.Coordinator?
    var grid: [UInt8] = [] {
        didSet { gridGeneration &+= 1 }
    }
    var gridW: Int = 0
    var gridH: Int = 0
    var cellSize: Int = 8
    var showGridLines: Bool = true
    var aliveColor: NSColor = .green
    var deadColor: NSColor = NSColor(white: 0.05, alpha: 1)
    var selectedTool: DrawTool = .pencil
    var selectedPattern: Pattern?
    var patternRotation: Int = 0
    var onHoverChange: (((row: Int, col: Int)?) -> Void)?
    var onShapePreviewChange: (((r0: Int, c0: Int, r1: Int, c1: Int)?) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var initialZoom: CGFloat = 8

    /// Applies the representable's state, touching only what actually changed.
    ///
    /// `grid` bumps `gridGeneration`, and a generation change invalidates the
    /// cached bitmap. Assigning the grid on every SwiftUI update — while hovering,
    /// while a status-bar string redraws — rebuilt that bitmap for nothing.
    func apply(
        grid: [UInt8],
        gridW: Int,
        gridH: Int,
        cellSize: Int,
        showGridLines: Bool,
        aliveColor: NSColor,
        deadColor: NSColor,
        selectedTool: DrawTool,
        selectedPattern: Pattern?,
        patternRotation: Int
    ) {
        let appearanceChanged = self.aliveColor != aliveColor
            || self.deadColor != deadColor
            || self.gridW != gridW
            || self.gridH != gridH
            || self.cellSize != cellSize
            || !Pattern.equivalent(self.selectedPattern, selectedPattern)
            || self.patternRotation != patternRotation
        let displayChanged = self.showGridLines != showGridLines
            || self.selectedTool != selectedTool

        if self.grid != grid {
            self.grid = grid
            if appearanceChanged {
                cachedGridImage = nil
            }
        }
        self.gridW = gridW
        self.gridH = gridH
        self.cellSize = cellSize
        self.aliveColor = aliveColor
        self.deadColor = deadColor
        self.selectedPattern = selectedPattern
        self.patternRotation = patternRotation

        if appearanceChanged || displayChanged {
            self.showGridLines = showGridLines
            self.selectedTool = selectedTool
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var zoomLevel: CGFloat = 8
    private var panOffset: CGPoint = .zero
    private var needsInitialFit = true
    private var lastHoveredCell: (row: Int, col: Int)?
    private var lastShapePreview: (r0: Int, c0: Int, r1: Int, c1: Int)?
    private var isRightDragging = false
    private var isDrawing = false
    private var drawStartCell: (row: Int, col: Int)?
    private var lastDrawnCell: (row: Int, col: Int)?
    private var trackingArea: NSTrackingArea?

    private var cachedGridImage: CGImage?
    private var cachedImageGeneration: Int = -1
    private var gridGeneration: Int = 0
    private var cachedAliveColor: NSColor?
    private var cachedDeadColor: NSColor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.masksToBounds = true
        if window != nil {
            zoomLevel = initialZoom
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor())
    }

    private func currentCursor() -> NSCursor {
        switch selectedTool {
        case .pencil:  return .crosshair
        case .line:    return .crosshair
        case .rectangle: return .crosshair
        case .eraser:  return NSCursor(image: eraserCursorImage(), hotSpot: NSPoint(x: 4, y: 4))
        }
    }

    private func eraserCursorImage() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()
        let rect = NSRect(x: 1, y: 1, width: 14, height: 10)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        NSColor.white.setStroke()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 14, height: 10), xRadius: 2, yRadius: 2).stroke()
        image.unlockFocus()
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    func adjustZoom(_ factor: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let newZoom = min(max(zoomLevel * factor, 0.25), 32)
        panOffset.x = center.x - (center.x - panOffset.x) * (newZoom / zoomLevel)
        panOffset.y = center.y - (center.y - panOffset.y) * (newZoom / zoomLevel)
        zoomLevel = newZoom
        onZoomChange?(zoomLevel)
        needsDisplay = true
    }

    func resetView() {
        needsInitialFit = true
        needsDisplay = true
    }

    private func applyInitialFit() {
        guard gridW > 0, gridH > 0, bounds.width > 0, bounds.height > 0 else { return }

        let fitZoom = min(bounds.width / CGFloat(gridW * cellSize),
                          bounds.height / CGFloat(gridH * cellSize))
        zoomLevel = min(max(fitZoom, 0.25), 32)

        let fittedW = CGFloat(gridW * cellSize) * zoomLevel
        let fittedH = CGFloat(gridH * cellSize) * zoomLevel
        panOffset = CGPoint(
            x: (bounds.width - fittedW) / 2,
            y: (bounds.height - fittedH) / 2
        )
        onZoomChange?(zoomLevel)
        needsInitialFit = false
    }

    private func cellAtPoint(_ point: CGPoint) -> (row: Int, col: Int) {
        let cellDisplaySize = CGFloat(cellSize) * zoomLevel
        let col = Int(floor((point.x - panOffset.x) / cellDisplaySize))
        let row = Int(floor((point.y - panOffset.y) / cellDisplaySize))
        return (row, col)
    }

    private func rebuildGridBitmap() {
        guard gridW > 0, gridH > 0, grid.count >= gridW * gridH else {
            cachedGridImage = nil
            return
        }

        let bytesPerRow = gridW * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: gridW, height: gridH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            cachedGridImage = nil
            return
        }

        let aliveRGB = aliveColor.usingColorSpace(.sRGB) ?? aliveColor
        let deadRGB = deadColor.usingColorSpace(.sRGB) ?? deadColor

        let aliveR = UInt8(clamping: Int(aliveRGB.redComponent * 255))
        let aliveG = UInt8(clamping: Int(aliveRGB.greenComponent * 255))
        let aliveB = UInt8(clamping: Int(aliveRGB.blueComponent * 255))
        let deadR = UInt8(clamping: Int(deadRGB.redComponent * 255))
        let deadG = UInt8(clamping: Int(deadRGB.greenComponent * 255))
        let deadB = UInt8(clamping: Int(deadRGB.blueComponent * 255))

        let ptr = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<grid.count {
            let offset = i &* 4
            if grid[i] != 0 {
                ptr[offset] = aliveR
                ptr[offset &+ 1] = aliveG
                ptr[offset &+ 2] = aliveB
                ptr[offset &+ 3] = 255
            } else {
                ptr[offset] = deadR
                ptr[offset &+ 1] = deadG
                ptr[offset &+ 2] = deadB
                ptr[offset &+ 3] = 255
            }
        }

        cachedGridImage = context.makeImage()
        cachedImageGeneration = gridGeneration
        cachedAliveColor = aliveColor
        cachedDeadColor = deadColor
    }

    private func isValidCell(_ row: Int, _ col: Int) -> Bool {
        row >= 0 && row < gridH && col >= 0 && col < gridW
    }

    private func drawCell(_ row: Int, _ col: Int, alive: Bool) {
        guard isValidCell(row, col) else { return }
        let idx = row * gridW + col
        let value: UInt8 = alive ? 1 : 0
        if grid[idx] != value {
            grid[idx] = value
            gridGeneration &+= 1
        }
    }

    private func fillLine(from r0: Int, _ c0: Int, to r1: Int, _ c1: Int, alive: Bool) {
        // Reuse the library's Bresenham rather than a third private copy, so the
        // line the editor previews is the one the provider renders. `drawCell`
        // clips to the grid and only bumps `gridGeneration` on a real change.
        for cell in BrushTool.lineCells(fromRow: r0, fromCol: c0, toRow: r1, toCol: c1) {
            drawCell(cell.row, cell.col, alive: alive)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        isRightDragging = true
        NSCursor.closedHand.set()
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isRightDragging else { return }
        panOffset.x += event.deltaX
        panOffset.y += event.deltaY
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        isRightDragging = false
        NSCursor.arrow.set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        let mousePoint = convert(event.locationInWindow, from: nil)
        let factor: CGFloat = event.deltaY > 0 ? 1.0 / 1.1 : 1.1

        let newZoom = min(max(zoomLevel * factor, 0.25), 32)
        panOffset.x = mousePoint.x - (mousePoint.x - panOffset.x) * (newZoom / zoomLevel)
        panOffset.y = mousePoint.y - (mousePoint.y - panOffset.y) * (newZoom / zoomLevel)
        zoomLevel = newZoom
        onZoomChange?(zoomLevel)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellAtPoint(point)

        guard isValidCell(row, col) else { return }

        if let pattern = selectedPattern {
            let cells = pattern.rotated(by: patternRotation)
            for (dr, dc) in cells {
                drawCell(row + dr, col + dc, alive: true)
            }
            coordinator?.onGridChanged(grid)
            needsDisplay = true
            return
        }

        switch selectedTool {
        case .pencil:
            isDrawing = true
            lastDrawnCell = (row, col)
            drawCell(row, col, alive: true)
            needsDisplay = true
        case .eraser:
            isDrawing = true
            lastDrawnCell = (row, col)
            drawCell(row, col, alive: false)
            needsDisplay = true
        case .line, .rectangle:
            isDrawing = true
            drawStartCell = (row, col)
            let preview = (row, col, row, col)
            lastShapePreview = preview
            onShapePreviewChange?(preview)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellAtPoint(point)

        switch selectedTool {
        case .pencil:
            if let last = lastDrawnCell, isValidCell(row, col) {
                fillLine(from: last.row, last.col, to: row, col, alive: true)
                lastDrawnCell = (row, col)
                needsDisplay = true
            }
        case .eraser:
            if let last = lastDrawnCell, isValidCell(row, col) {
                fillLine(from: last.row, last.col, to: row, col, alive: false)
                lastDrawnCell = (row, col)
                needsDisplay = true
            }
        case .line, .rectangle:
            if let start = drawStartCell {
                let preview = (start.row, start.col, row, col)
                lastShapePreview = preview
                onShapePreviewChange?(preview)
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing else { return }
        isDrawing = false

        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellAtPoint(point)

        switch selectedTool {
        case .pencil, .eraser:
            lastDrawnCell = nil
            coordinator?.onGridChanged(grid)

        case .line:
            if let start = drawStartCell {
                fillLine(from: start.row, start.col, to: row, col, alive: true)
                coordinator?.onShapeComplete(start.row, start.col, row, col, selectedTool)
                drawStartCell = nil
                lastShapePreview = nil
                onShapePreviewChange?(nil)
            }

        case .rectangle:
            if let start = drawStartCell {
                let minR = min(start.row, row)
                let maxR = max(start.row, row)
                let minC = min(start.col, col)
                let maxC = max(start.col, col)
                for r in minR...maxR {
                    for c in minC...maxC {
                        drawCell(r, c, alive: true)
                    }
                }
                coordinator?.onShapeComplete(start.row, start.col, row, col, selectedTool)
                drawStartCell = nil
                lastShapePreview = nil
                onShapePreviewChange?(nil)
            }
        }

        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellAtPoint(point)
        if isValidCell(row, col) {
            let cell = (row, col)
            lastHoveredCell = cell
            onHoverChange?(cell)
        } else {
            lastHoveredCell = nil
            onHoverChange?(nil)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        lastHoveredCell = nil
        onHoverChange?(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if needsInitialFit {
            applyInitialFit()
        }

        let bgColor: NSColor = .controlBackgroundColor
        bgColor.setFill()
        bounds.fill()

        guard gridW > 0, gridH > 0 else { return }

        let cellDisplaySize = CGFloat(cellSize) * zoomLevel
        let context = NSGraphicsContext.current!.cgContext

        let colorChanged = aliveColor != cachedAliveColor || deadColor != cachedDeadColor
        if gridGeneration != cachedImageGeneration || colorChanged {
            rebuildGridBitmap()
        }

        if let image = cachedGridImage {
            let gridRect = CGRect(
                x: panOffset.x,
                y: panOffset.y,
                width: CGFloat(gridW) * cellDisplaySize,
                height: CGFloat(gridH) * cellDisplaySize
            )
            context.saveGState()
            context.translateBy(x: gridRect.minX, y: gridRect.minY + gridRect.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridRect.width, height: gridRect.height))
            context.restoreGState()
        }

        if showGridLines, cellDisplaySize >= 4 {
            NSColor.quaternaryLabelColor.setStroke()
            context.setLineWidth(0.5)

            let minCol = max(0, Int(floor((dirtyRect.minX - panOffset.x) / cellDisplaySize)))
            let maxCol = min(gridW, Int(ceil((dirtyRect.maxX - panOffset.x) / cellDisplaySize)))
            let minRow = max(0, Int(floor((dirtyRect.minY - panOffset.y) / cellDisplaySize)))
            let maxRow = min(gridH, Int(ceil((dirtyRect.maxY - panOffset.y) / cellDisplaySize)))

            for col in minCol...maxCol {
                let x = panOffset.x + CGFloat(col) * cellDisplaySize
                context.move(to: CGPoint(x: x, y: panOffset.y + CGFloat(minRow) * cellDisplaySize))
                context.addLine(to: CGPoint(x: x, y: panOffset.y + CGFloat(maxRow) * cellDisplaySize))
            }
            for row in minRow...maxRow {
                let y = panOffset.y + CGFloat(row) * cellDisplaySize
                context.move(to: CGPoint(x: panOffset.x + CGFloat(minCol) * cellDisplaySize, y: y))
                context.addLine(to: CGPoint(x: panOffset.x + CGFloat(maxCol) * cellDisplaySize, y: y))
            }
            context.strokePath()
        }

        if let (hoverRow, hoverCol) = lastHoveredCell,
           isValidCell(hoverRow, hoverCol) {
            let hoverRect = CGRect(
                x: panOffset.x + CGFloat(hoverCol) * cellDisplaySize,
                y: panOffset.y + CGFloat(hoverRow) * cellDisplaySize,
                width: cellDisplaySize,
                height: cellDisplaySize
            )
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            context.fill(hoverRect)
        }

        if let pattern = selectedPattern,
           let (hoverRow, hoverCol) = lastHoveredCell {
            let cells = pattern.rotated(by: patternRotation)
            NSColor.systemYellow.withAlphaComponent(0.4).setFill()
            for (dr, dc) in cells {
                let pr = hoverRow + dr
                let pc = hoverCol + dc
                guard isValidCell(pr, pc) else { continue }
                let cellRect = CGRect(
                    x: panOffset.x + CGFloat(pc) * cellDisplaySize,
                    y: panOffset.y + CGFloat(pr) * cellDisplaySize,
                    width: cellDisplaySize,
                    height: cellDisplaySize
                )
                context.fill(cellRect)
            }
        }

        if let (r0, c0, r1, c1) = lastShapePreview {
            switch selectedTool {
            case .line:
                let x0 = panOffset.x + (CGFloat(c0) + 0.5) * cellDisplaySize
                let y0 = panOffset.y + (CGFloat(r0) + 0.5) * cellDisplaySize
                let x1 = panOffset.x + (CGFloat(c1) + 0.5) * cellDisplaySize
                let y1 = panOffset.y + (CGFloat(r1) + 0.5) * cellDisplaySize
                NSColor.systemYellow.withAlphaComponent(0.5).setStroke()
                context.setLineWidth(2)
                context.move(to: CGPoint(x: x0, y: y0))
                context.addLine(to: CGPoint(x: x1, y: y1))
                context.strokePath()
                return
            case .rectangle:
                let minC = min(c0, c1)
                let maxC = max(c0, c1)
                let minR = min(r0, r1)
                let maxR = max(r0, r1)
                let previewRect = CGRect(
                    x: panOffset.x + CGFloat(minC) * cellDisplaySize,
                    y: panOffset.y + CGFloat(minR) * cellDisplaySize,
                    width: CGFloat(maxC - minC + 1) * cellDisplaySize,
                    height: CGFloat(maxR - minR + 1) * cellDisplaySize
                )
                NSColor.systemYellow.withAlphaComponent(0.25).setFill()
                context.fill(previewRect)
                NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
                context.setLineWidth(1.5)
                context.stroke(previewRect)
            case .pencil, .eraser:
                break
            }
        }
    }
}