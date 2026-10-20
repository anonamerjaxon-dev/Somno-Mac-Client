import AppKit

final class CanvasWindow: NSWindow {

    private var renderers: [UUID: CanvasRenderer] = [:]
    private var providers: [UUID: any CanvasProvider] = [:]

    /// The screen this window covers, re-read on every layout pass so a
    /// display re-configuration cannot leave stale geometry behind.
    private let coveredScreen: NSScreen

    init(screen: NSScreen) {
        self.coveredScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        self.level = NSWindow.Level(rawValue: Int(iconLevel))
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.backgroundColor = .clear
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
            .ignoresCycle
        ]

        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = .clear

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOcclusionChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )

        self.order(.below, relativeTo: 0)
    }

    @objc private func handleOcclusionChange() {
        if occlusionState.contains(.visible) {
            contentView?.setNeedsDisplay(contentView?.bounds ?? .zero)
        }
    }

    func provider<T>(for canvasID: UUID, as type: T.Type) -> T? {
        providers[canvasID] as? T
    }

    /// Every Game of Life provider currently hosted by this window, so setup
    /// failures can be collected and reported instead of leaving a blank canvas.
    func gameOfLifeProviders() -> [GameOfLifeProvider] {
        providers.values.compactMap { $0 as? GameOfLifeProvider }
    }

    func pauseAllProviders() {
        for provider in providers.values {
            provider.pause()
        }
    }

    func resumeAllProviders() {
        for provider in providers.values {
            provider.resume()
        }
    }

    func reorderToDesktop() {
        self.order(.below, relativeTo: 0)
        contentView?.setNeedsDisplay(contentView?.bounds ?? .zero)
    }

    /// Re-anchors the window to a new screen frame after a display
    /// re-configuration. Window level, ordering and collection behaviour are
    /// deliberately left untouched so the desktop stays spike-faithful.
    func reframe(to newFrame: CGRect) {
        guard newFrame != frame else { return }
        setFrame(newFrame, display: true)
        contentView?.setNeedsDisplay(contentView?.bounds ?? .zero)
    }

    func setBackgroundColor(_ color: NSColor?) {
        guard let color else {
            backgroundColor = .clear
            contentView?.layer?.backgroundColor = .clear
            return
        }
        backgroundColor = color
        contentView?.layer?.backgroundColor = color.cgColor
    }

    /// Places `canvases` inside this window. Frames arrive in global canvas
    /// coordinates and are translated into the window's screen-local space
    /// (see `ScreenGeometry`) so a secondary display no longer receives a full
    /// copy of the primary display's layout.
    func layoutCanvases(_ canvases: [CanvasModel]) {
        guard let contentView = contentView else { return }

        let screenFrame = coveredScreen.frame
        let newIDs = Set(canvases.map(\.id))
        let oldIDs = Set(renderers.keys)

        for id in oldIDs.subtracting(newIDs) {
            if let provider = providers[id] {
                provider.detach()
            }
            renderers[id]?.removeFromSuperview()
            renderers[id] = nil
            providers[id] = nil
        }

        for canvas in canvases {
            guard let existing = renderers[canvas.id],
                  let provider = providers[canvas.id] else { continue }
            let typeChanged: Bool = switch canvas.type {
            case .gameOfLife: !(provider is GameOfLifeProvider)
            case .video: !(provider is VideoProvider)
            }
            if typeChanged {
                provider.detach()
                existing.removeFromSuperview()
                renderers[canvas.id] = nil
                providers[canvas.id] = nil
            }
        }

        for canvas in canvases where renderers[canvas.id] == nil {
            let provider: any CanvasProvider = switch canvas.type {
            case .gameOfLife:
                GameOfLifeProvider(canvas: canvas)
            case .video:
                VideoProvider(canvas: canvas)
            }

            let renderer = CanvasRenderer(provider: provider)
            renderers[canvas.id] = renderer
            providers[canvas.id] = provider
        }

        for canvas in canvases {
            guard let renderer = renderers[canvas.id],
                  let provider = providers[canvas.id] else { continue }
            provider.canvas = canvas
            renderer.frame = ScreenGeometry.localFrame(for: canvas.frame, in: screenFrame)
            provider.update()
        }

        for canvas in canvases {
            guard let renderer = renderers[canvas.id] else { continue }
            if renderer.superview !== contentView {
                contentView.addSubview(renderer)
            }
        }
    }
}