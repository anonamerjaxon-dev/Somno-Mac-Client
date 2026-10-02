import SwiftUI

final class TrailWindow: NSWindow {
    let model: TrailModel

    /// - Parameter screen: the display the overlay should cover. Defaults to the main
    ///   screen. Pass the screen under the cursor so a trail follows the user onto a
    ///   secondary display instead of being pinned to the main one.
    init(configuration: TrailConfiguration = .init(), screen: NSScreen? = nil) {
        self.model = TrailModel()
        let contentView = TrailContentView(configuration: configuration, model: model)
        let hostingController = NSHostingController(rootView: contentView)

        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.contentViewController = hostingController
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = screen ?? NSScreen.main {
            self.setFrame(screen.frame, display: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ points: RingBuffer<TrailPoint>) {
        model.trailPoints = points
    }
}

final class TrailModel: ObservableObject {
    @Published var trailPoints: RingBuffer<TrailPoint> = .init(capacity: 100)
}

struct TrailContentView: View {
    @ObservedObject var model: TrailModel
    private let renderer: TrailRenderer

    init(configuration: TrailConfiguration = .init(), model: TrailModel) {
        self.renderer = TrailRenderer(configuration: configuration)
        self.model = model
    }

    var body: some View {
        Canvas { context, _ in
            renderer.draw(context: context, points: model.trailPoints)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}