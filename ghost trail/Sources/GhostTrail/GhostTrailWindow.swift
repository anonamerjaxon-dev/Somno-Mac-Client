import AppKit
import SwiftUI

final class GhostTrailWindow: NSWindow {
    private let model: GhostTrailModel

    init(configuration: GhostTrailConfiguration) {
        let model = GhostTrailModel()
        let renderer = GhostTrailRenderer(configuration: configuration)

        // Cover every screen, not just `NSScreen.main`: window frames arrive in
        // global Quartz coordinates, and trails dragged on a secondary display
        // would otherwise fall outside a main-screen-sized overlay.
        let screenUnion = Self.coveringFrame()
        let hasScreens = !screenUnion.isEmpty
        let frame = hasScreens ? screenUnion : NSRect(x: 0, y: 0, width: 1, height: 1)

        // The overlay spans the union of all screens, so every quartz window rect has
        // to be flipped about the MAIN display and translated by the overlay origin
        // before it can be drawn in view space.
        let converter: TrailCoordinateConverter
        if let mainDisplay = NSScreen.main ?? NSScreen.screens.first {
            converter = TrailCoordinateConverter(
                mainDisplayFrame: mainDisplay.frame,
                overlayFrame: frame
            )
        } else {
            converter = .identity
        }

        let contentView = GhostTrailContentView(model: model, renderer: renderer, converter: converter)
        let hostingController = NSHostingController(rootView: contentView)

        self.model = model

        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.contentViewController = hostingController
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        switch configuration.windowLevel {
        case .aboveWindows:
            self.level = .floating
        case .behindWindows:
            self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        }

        if !hasScreens {
            // No display attached (headless / all screens asleep): degrade to a 1×1
            // window rather than trapping on the previously fatal screen guard.
            print("[GhostTrail] WARNING: no display attached; trail will not render")
        }

        self.setFrame(frame, display: !hasScreens ? false : true)
        hostingController.view.frame = NSRect(origin: .zero, size: frame.size)
        hostingController.view.autoresizingMask = [.width, .height]
    }

    /// Union of all screen frames, in global (Quartz-origin) coordinates.
    static func coveringFrame() -> NSRect {
        let screens = NSScreen.screens
        guard let first = screens.first else { return .zero }
        var union = first.frame
        for screen in screens.dropFirst() {
            union = union.union(screen.frame)
        }
        return union
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(trails: [CGWindowID: RingBuffer<TrailFrame>]) {
        model.trails = trails
    }
}

final class GhostTrailModel: ObservableObject {
    @Published var trails: [CGWindowID: RingBuffer<TrailFrame>] = [:]
}

struct GhostTrailContentView: View {
    @ObservedObject var model: GhostTrailModel
    let renderer: GhostTrailRenderer
    var converter: TrailCoordinateConverter = .identity

    var body: some View {
        Canvas { context, size in
            renderer.draw(context: context,
                          trails: model.trails,
                          size: size,
                          converter: converter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}