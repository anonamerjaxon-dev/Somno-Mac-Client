import AppKit
import SwiftUI

final class GhostTrailWindow: NSWindow {
    private let model: GhostTrailModel

    /// Quartz → view conversion this overlay draws with.
    ///
    /// `GhostTrail` needs it too: the rectangles it punches out of the ribbon
    /// have to be built in the same space as the ribbon itself, or the holes
    /// land mirrored and nothing lines up.
    let converter: TrailCoordinateConverter

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
        self.converter = converter

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
            // macOS composites NOTHING below `kCGNormalWindowLevel` — measured,
            // not assumed: a 400×200pt window at `kCGDesktopIconWindowLevel`,
            // at `normal - 1`, and at every level in between produced 475 pixels
            // in a screenshot, identical to an off-screen baseline, while the
            // same window at `kCGNormalWindowLevel` produced 320,475. Setting
            // the level below zero therefore produced a window that existed,
            // reported its layer to `CGWindowListCopyWindowInfo`, and was never
            // drawn. Every trail since the rewrite has been invisible.
            //
            // So the overlay goes one point ABOVE normal windows and the depth
            // illusion is produced by erasing the ribbon where a real window
            // covers it — see `WindowOccluders`. Just above normal (rather than
            // `.floating`) keeps the trail under panels, menus and the status
            // items, so those never smear across the effect.
            self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
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

    func update(trails: [CGWindowID: RingBuffer<TrailSample>]) {
        model.trails = trails
    }

    /// Publishes the on-screen window frames the renderer must cut the ribbon
    /// around. Kept separate from `update` so the occluder set is republished
    /// even on ticks where no window moved.
    func updateOccluders(_ rects: [CGRect]) {
        model.occluders = rects
    }
}

final class GhostTrailModel: ObservableObject {
    @Published var trails: [CGWindowID: RingBuffer<TrailSample>] = [:]
    /// Visible frames, in overlay-view coordinates, that the trail must appear
    /// to pass beneath.
    @Published var occluders: [CGRect] = []
}

struct GhostTrailContentView: View {
    @ObservedObject var model: GhostTrailModel
    let renderer: GhostTrailRenderer
    var converter: TrailCoordinateConverter = .identity

    var body: some View {
        Canvas { context, size in
            renderer.draw(context: context,
                          trails: model.trails,
                          occluders: model.occluders,
                          size: size,
                          converter: converter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}