import Foundation
import CoreVideo
import AppKit
import QuartzCore

public final class GhostTrail {
    public static var current: GhostTrail?

    private var configuration: GhostTrailConfiguration
    private var trailWindow: GhostTrailWindow?
    private var windowTracker: WindowTracker?
    private var isRunning: Bool = false
    private var displayLink: AnyObject?
    private var displayLinkTarget: DisplayLinkTarget?
    private var displayLinkUserInfo: UnsafeMutableRawPointer?
    /// Typed storage for the legacy (macOS 13–14) `CVDisplayLink`. Kept separate from
    /// `displayLink` so teardown can nil-check it without a force-cast from `AnyObject`.
    private var legacyDisplayLink: CVDisplayLink?

    /// Serializes display-link teardown against in-flight callbacks. The legacy
    /// CVDisplayLink callback and `stopDisplayLink()` run on different threads, so
    /// the unmanaged self-reference stored in `displayLinkUserInfo` must never be
    /// released while a callback can still reach it.
    private let displayLinkLock = NSLock()

    /// Minimum seconds between `CGWindowListCopyWindowInfo` polls (~30 Hz).
    private var lastPollTime: CFTimeInterval = 0
    private let pollInterval: CFTimeInterval = 1.0 / 30.0

    deinit {
        if GhostTrail.current === self {
            GhostTrail.current = nil
        }
        stopDisplayLink()
    }

    // MARK: - Builder

    public init() {
        self.configuration = GhostTrailConfiguration()
    }

    @discardableResult
    public func strokeColor(_ color: TrailColor) -> GhostTrail {
        configuration.strokeColor = color
        return self
    }

    @discardableResult
    public func strokeWidth(_ width: CGFloat) -> GhostTrail {
        configuration.strokeWidth = max(width, 0.5)
        return self
    }

    @discardableResult
    public func frameCount(_ count: Int) -> GhostTrail {
        configuration.frameCount = max(count, 10)
        return self
    }

    @discardableResult
    public func fadeDuration(_ duration: TimeInterval) -> GhostTrail {
        configuration.fadeDuration = max(duration, 0.1)
        return self
    }

    @discardableResult
    public func movementThreshold(_ threshold: CGFloat) -> GhostTrail {
        configuration.movementThreshold = max(threshold, 1)
        return self
    }

    /// Position delta above which a window is treated as having jumped (teleported)
    /// rather than dragged, so its stale trail is discarded.
    @discardableResult
    public func jumpThreshold(_ threshold: CGFloat) -> GhostTrail {
        configuration.jumpThreshold = max(threshold, 1)
        return self
    }

    /// Corner radius applied to every rendered window outline. `0` draws sharp
    /// rectangles. Clamped to >= 0.
    @discardableResult
    public func cornerRadius(_ radius: CGFloat) -> GhostTrail {
        configuration.cornerRadius = max(radius, 0)
        return self
    }

    /// Whether the trail draws over windows (`.aboveWindows`) or behind them
    /// (`.behindWindows`, the default — the trail sits *under* the window being
    /// dragged so it never obscures the thing the user is looking at).
    @discardableResult
    public func windowLevel(_ level: TrailWindowLevel) -> GhostTrail {
        configuration.windowLevel = level
        return self
    }

    @discardableResult
    public func opacity(_ value: Double) -> GhostTrail {
        configuration.opacity = max(min(value, 1.0), 0.0)
        return self
    }

    @discardableResult
    public func style(_ style: TrailStyle) -> GhostTrail {
        configuration.style = style
        return self
    }

    @discardableResult
    public func glow(_ config: GlowConfig) -> GhostTrail {
        configuration.glow = config
        return self
    }

    @discardableResult
    public func preset(_ config: GhostTrailConfiguration) -> GhostTrail {
        self.configuration = config
        return self
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return false }

        print("[GhostTrail] start() called")

        let tracker = WindowTracker(
            frameCount: configuration.frameCount,
            fadeDuration: configuration.fadeDuration,
            movementThreshold: configuration.movementThreshold,
            jumpThreshold: configuration.jumpThreshold
        )
        windowTracker = tracker

        let window = GhostTrailWindow(configuration: configuration)
        trailWindow = window
        window.orderFrontRegardless()

        guard startDisplayLink() else {
            // Display link creation failed: tear down so we don't leave a live
            // overlay with nothing driving it.
            print("[GhostTrail] ERROR: display link creation failed")
            trailWindow?.orderOut(nil as Any?)
            trailWindow = nil
            windowTracker = nil
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
        trailWindow?.orderOut(nil as Any?)
        trailWindow = nil
        windowTracker?.clearAll()
        windowTracker = nil
        isRunning = false
        if GhostTrail.current === self {
            GhostTrail.current = nil
        }
    }

    // MARK: - Display Link

    private func startDisplayLink() -> Bool {
        stopDisplayLink()
        print("[GhostTrail] startDisplayLink() called")

        if #available(macOS 15.0, *) {
            let target = DisplayLinkTarget(ghostTrail: self)
            displayLinkTarget = target
            guard let screen = activeScreen() else {
                print("[GhostTrail] ERROR: no main screen")
                return false
            }
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.fire))
            link.add(to: .main, forMode: .common)
            displayLink = link
            print("[GhostTrail] Display link started (macOS 15+ CADisplayLink path)")
            return true
        } else {
            print("[GhostTrail] Starting legacy CVDisplayLink")
            return startLegacyDisplayLink()
        }
    }

    @available(macOS, deprecated: 15.0, message: "CVDisplayLink used for macOS 13-14 compatibility")
    private func startLegacyDisplayLink() -> Bool {
        var cvLink: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&cvLink)
        guard createStatus == kCVReturnSuccess, let link = cvLink else {
            print("[GhostTrail] ERROR: CVDisplayLinkCreateWithActiveCGDisplays failed (\(createStatus))")
            return false
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnError }
            let trail = Unmanaged<GhostTrail>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { [weak trail] in
                trail?.updateTrail()
            }
            return kCVReturnSuccess
        }

        let unmanaged = Unmanaged.passUnretained(self)
        displayLinkLock.lock()
        displayLinkUserInfo = unmanaged.toOpaque()
        legacyDisplayLink = link
        displayLinkLock.unlock()

        CVDisplayLinkSetOutputCallback(link, callback, unmanaged.toOpaque())
        let startStatus = CVDisplayLinkStart(link)
        guard startStatus == kCVReturnSuccess else {
            displayLinkLock.lock()
            legacyDisplayLink = nil
            displayLinkUserInfo = nil
            displayLinkLock.unlock()
            print("[GhostTrail] ERROR: CVDisplayLinkStart failed (\(startStatus))")
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
            stopLegacyDisplayLinkLocked()
        }
    }

    @available(macOS, deprecated: 15.0, message: "CVDisplayLink used for macOS 13-14 compatibility")
    private func stopLegacyDisplayLinkLocked() {
        // Typed storage, not `displayLink as! CVDisplayLink`: the force-cast trapped
        // on macOS 13/14 whenever `startDisplayLink()` bailed out early or was never
        // called at all — including `deinit` of a never-started instance.
        guard let link = legacyDisplayLink else {
            legacyDisplayLink = nil
            displayLinkUserInfo = nil
            return
        }
        CVDisplayLinkStop(link)
        legacyDisplayLink = nil
        displayLinkUserInfo = nil
    }

    // MARK: - Screen Geometry

    /// The screen whose frame the overlay is currently anchored to. The overlay is
    /// sized to the union of all screens, so trails on any display land in the
    /// overlay's local coordinates after a single CG→AppKit y-flip.
    private func activeScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Trail Update

    fileprivate func updateTrail() {
        guard isRunning, let tracker = windowTracker else { return }

        // `CGWindowListCopyWindowInfo` is a system-wide, permission-checked call —
        // far too expensive for every display-link frame at 60–120 Hz. Throttle to
        // ~30 Hz; rendering still happens at refresh rate.
        let now = CACurrentMediaTime()
        guard now - lastPollTime >= pollInterval else { return }
        lastPollTime = now

        let trails = tracker.poll()
        trailWindow?.update(trails: trails)
    }
}

// MARK: - DisplayLink Target (macOS 15+)

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