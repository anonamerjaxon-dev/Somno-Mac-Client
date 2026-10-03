import AppKit
import SwiftUI
import QuartzCore

/// Coordinates the three moving parts of the effect: which windows the user is
/// actually touching, the geometry history of those windows, and the overlay
/// that draws the history.
///
/// Public surface is unchanged from the previous implementation — the same
/// builder methods, the same `start()`/`stop()`, the same `GhostTrail.current`
/// — so the rewrite is source-compatible with existing callers.
public final class GhostTrail {
    public static var current: GhostTrail?

    private var configuration: GhostTrailConfiguration
    private var trailWindow: GhostTrailWindow?

    /// Quartz → overlay-view converter, shared with the window so the occluder
    /// rectangles and the ribbon are built in the same coordinate space. Without
    /// this the punched-out windows would be mirrored relative to the ribbon and
    /// nothing would line up.
    private var trailConverter: TrailCoordinateConverter = .identity
    private var windowTracker: WindowTracker?
    private var dragTracker: DragSessionTracker?
    private var isRunning = false

    private var displayLink: AnyObject?
    private var displayLinkTarget: DisplayLinkTarget?
    private var legacyDisplayLink: CVDisplayLink?
    private var displayLinkUserInfo: UnsafeMutableRawPointer?
    private let displayLinkLock = NSLock()

    /// Minimum seconds between `CGWindowListCopyWindowInfo` polls (~30 Hz).
    /// That call is system-wide and permission-checked; running it at display
    /// refresh rate costs far more than the rendering it feeds.
    private var lastPollTime: CFTimeInterval = 0
    private let pollInterval: CFTimeInterval = 1.0 / 30.0

    /// True when the event tap could not be installed and eligibility is
    /// falling back to pure geometry. Surfaced so a caller can warn the user
    /// that Accessibility permission would improve the result.
    public private(set) var isUsingGeometryFallback = false

    /// How many windows were drawing a ribbon at the last poll. Zero while the
    /// user is not touching a window; >1 when two windows are dragged at once.
    /// Diagnostic — useful from a demo HUD, and the cheapest way to tell a
    /// permissions problem from a hit-testing problem.
    public private(set) var activeTrailCount = 0

    deinit {
        if GhostTrail.current === self {
            GhostTrail.current = nil
        }
        stopDisplayLink()
    }

    public init() {
        self.configuration = GhostTrailConfiguration()
    }

    // MARK: - Builder

    @discardableResult public func strokeColor(_ color: TrailColor) -> GhostTrail {
        configuration.strokeColor = color
        return self
    }

    @discardableResult public func strokeWidth(_ width: CGFloat) -> GhostTrail {
        configuration.strokeWidth = max(width, 0.5)
        return self
    }

    @discardableResult public func frameCount(_ count: Int) -> GhostTrail {
        configuration.frameCount = max(count, 2)
        return self
    }

    @discardableResult public func fadeDuration(_ duration: TimeInterval) -> GhostTrail {
        configuration.fadeDuration = max(duration, 0.05)
        return self
    }

    @discardableResult public func cornerRadius(_ radius: CGFloat) -> GhostTrail {
        configuration.cornerRadius = max(radius, 0)
        return self
    }

    @discardableResult public func windowLevel(_ level: TrailWindowLevel) -> GhostTrail {
        configuration.windowLevel = level
        return self
    }

    @discardableResult public func opacity(_ value: Double) -> GhostTrail {
        configuration.opacity = max(min(value, 1), 0)
        return self
    }

    @discardableResult public func preset(_ config: GhostTrailConfiguration) -> GhostTrail {
        configuration = config
        return self
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return false }

        let tracker = WindowTracker(
            historyCapacity: configuration.historyCapacity,
            fadeDuration: configuration.fadeDuration,
            tuning: TrailTuning(
                minDistance: configuration.movementThreshold,
                snapDistance: configuration.snapDistance
            )
        )
        windowTracker = tracker

        let dragTracker = DragSessionTracker()
        if !dragTracker.start() {
            // No Accessibility permission: fall back to trailing anything that
            // moves. Softer behaviour beats no effect at all.
            isUsingGeometryFallback = true
        }
        self.dragTracker = dragTracker

        let window = GhostTrailWindow(configuration: configuration)
        trailWindow = window
        trailConverter = window.converter
        window.orderFrontRegardless()

        guard startDisplayLink() else {
            trailWindow?.orderOut(nil as Any?)
            trailWindow = nil
            windowTracker = nil
            self.dragTracker?.stop()
            self.dragTracker = nil
            return false
        }

        isRunning = true
        let previous = GhostTrail.current
        GhostTrail.current = nil
        previous?.stop()
        GhostTrail.current = self
        return true
    }

    public func stop() {
        guard isRunning else { return }

        stopDisplayLink()
        dragTracker?.stop()
        dragTracker = nil
        trailWindow?.orderOut(nil as Any?)
        trailWindow = nil
        windowTracker?.clearAll()
        windowTracker = nil
        isRunning = false
        isUsingGeometryFallback = false
        activeTrailCount = 0
        if GhostTrail.current === self {
            GhostTrail.current = nil
        }
    }

    // MARK: - Display link

    private func startDisplayLink() -> Bool {
        stopDisplayLink()

        if #available(macOS 15.0, *) {
            let target = DisplayLinkTarget(ghostTrail: self)
            displayLinkTarget = target
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.fire))
            link.add(to: .main, forMode: .common)
            displayLink = link
            return true
        }

        return startLegacyDisplayLink()
    }

    @available(macOS, deprecated: 15.0, message: "CVDisplayLink used for macOS 13-14 compatibility")
    private func startLegacyDisplayLink() -> Bool {
        var cvLink: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&cvLink)
        guard createStatus == kCVReturnSuccess, let link = cvLink else { return false }

        let unmanaged = Unmanaged.passUnretained(self)

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnError }
            let trail = Unmanaged<GhostTrail>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { [weak trail] in
                trail?.updateTrail()
            }
            return kCVReturnSuccess
        }

        displayLinkLock.lock()
        displayLinkUserInfo = unmanaged.toOpaque()
        legacyDisplayLink = link
        displayLinkLock.unlock()

        CVDisplayLinkSetOutputCallback(link, callback, unmanaged.toOpaque())
        guard CVDisplayLinkStart(link) == kCVReturnSuccess else {
            displayLinkLock.lock()
            legacyDisplayLink = nil
            displayLinkUserInfo = nil
            displayLinkLock.unlock()
            return false
        }
        return true
    }

    private func stopDisplayLink() {
        displayLinkLock.lock()
        defer { displayLinkLock.unlock() }

        if #available(macOS 15.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
            displayLink = nil
            displayLinkTarget = nil
        } else {
            if let link = legacyDisplayLink {
                CVDisplayLinkStop(link)
            }
            legacyDisplayLink = nil
            displayLinkUserInfo = nil
        }
    }

    // MARK: - Trail update

    fileprivate func updateTrail() {
        guard isRunning, let tracker = windowTracker else { return }

        let now = CACurrentMediaTime()
        guard now - lastPollTime >= pollInterval else { return }
        lastPollTime = now

        let frames = WindowTracker.currentWindowFrames(excludingPID: ProcessInfo.processInfo.processIdentifier)
        dragTracker?.updateWindowOrder(frames)

        let eligible: Set<CGWindowID>
        if let dragTracker, dragTracker.isRunning {
            eligible = dragTracker.eligibleWindows
        } else {
            eligible = Set(frames.keys)
        }

        let trails = tracker.poll(eligible: eligible, now: now)
        activeTrailCount = trails.count

        // Republish the frames the renderer must cut the ribbon around. This is a
        // second `CGWindowListCopyWindowInfo` call — the same one `currentWindowFrames`
        // already made a few lines above — and it is deliberately kept separate
        // because it filters on *visible* layers (normal + floating) rather than
        // on the layer-0 windows that can produce trails.
        //
        // Two calls per tick at 30Hz is 0.7ms of the 33ms budget, measured on
        // this machine. Folding the two filters into one pass is an easy win if
        // the profile ever says it matters.
        let occluders = WindowOccluders.visibleFrames(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        ).map { trailConverter.viewRect(fromQuartz: $0) }
        trailWindow?.updateOccluders(occluders)

        trailWindow?.update(trails: trails)
    }
}

/// The macOS 15+ path drives a callback target; the legacy path uses an
/// unmanaged self-reference registered with the `CVDisplayLink`.
private final class DisplayLinkTarget: NSObject {
    private weak var ghostTrail: GhostTrail?

    init(ghostTrail: GhostTrail) {
        self.ghostTrail = ghostTrail
        super.init()
    }

    @objc func fire() {
        ghostTrail?.updateTrail()
    }
}