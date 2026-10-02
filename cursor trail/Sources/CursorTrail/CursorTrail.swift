import Foundation
import QuartzCore
import AppKit
import CoreVideo

/// Pure result of one idle-fade tick. Extracted so the fade math is testable
/// without an `NSWindow` or a live display link.
struct IdleFadeStep {
    /// How many points the ring buffer should shed this frame.
    var removed: Int
    /// The carried-over accumulator, clamped to `CursorTrail.maxFadeAccumulator`.
    var accumulator: Double
}

public final class CursorTrail {
    /// The single active trail, if any.
    ///
    /// This is deliberately **weak**. A strong static would own the trail forever,
    /// which made `deinit { stop() }` unreachable while running — the trail leaked a
    /// running overlay that no caller could stop (the "zombie overlay" bug). Ownership
    /// now belongs to the caller: drop the last strong reference and the trail stops.
    public static weak var current: CursorTrail?

    private var configuration: TrailConfiguration
    private var trailWindow: TrailWindow?
    private var trailPoints: RingBuffer<TrailPoint>
    private var lastMouseLocation: CGPoint = .zero
    private var isRunning: Bool = false
    private var displayLink: CVDisplayLink?
    private var displayLinkContext: DisplayLinkContext?
    private var fadeAccumulator: Double = 0
    private var screenFrame: CGRect = .zero

    /// True while this instance owns the overlay and the display link.
    /// Internal so the test suite can assert lifecycle transitions.
    var isActive: Bool { isRunning }

    /// The screen-space rectangle the trail is being drawn into. Internal for tests.
    var activeScreenFrame: CGRect { screenFrame }

    /// Points currently buffered. Internal for tests.
    var bufferedPointCount: Int { trailPoints.count }

    deinit {
        // `deinit` can run on any thread, so it must NOT go through `stop()` (which
        // asserts the main queue). Tear the main-thread-only resources down inline
        // when we happen to be on main, otherwise hand them to the main queue. The
        // locals keep them alive until the closure runs.
        let link = displayLink
        let context = displayLinkContext
        let window = trailWindow
        displayLink = nil
        displayLinkContext = nil
        trailWindow = nil
        trailPoints.clear()
        isRunning = false

        if Thread.isMainThread {
            Self.finishTeardown(link: link, context: context, window: window)
        } else {
            DispatchQueue.main.async {
                Self.finishTeardown(link: link, context: context, window: window)
            }
        }
    }

    // MARK: - Builder

    public init() {
        self.configuration = TrailConfiguration()
        self.trailPoints = RingBuffer(capacity: configuration.length)
    }

    @discardableResult
    public func color(_ color: TrailColor) -> CursorTrail {
        configuration.color = color
        return self
    }

    @discardableResult
    public func thickness(_ thickness: CGFloat) -> CursorTrail {
        configuration.thickness = max(thickness, 1)
        return self
    }

    @discardableResult
    public func length(_ length: Int) -> CursorTrail {
        configuration.length = max(length, 10)
        trailPoints = RingBuffer(capacity: configuration.length)
        return self
    }

    @discardableResult
    public func fadeSpeed(_ speed: Double) -> CursorTrail {
        configuration.fadeSpeed = max(speed, 0.1)
        return self
    }

    @discardableResult
    public func rainbowSpeed(_ speed: Double) -> CursorTrail {
        configuration.rainbowSpeed = max(speed, 0.1)
        return self
    }

    @discardableResult
    public func diminishing(_ enabled: Bool) -> CursorTrail {
        configuration.diminishing = enabled
        return self
    }

    @discardableResult
    public func diminishingIntensity(_ intensity: Double) -> CursorTrail {
        configuration.diminishingIntensity = max(min(intensity, 1.0), 0.0)
        return self
    }

    @discardableResult
    public func style(_ style: TrailStyle) -> CursorTrail {
        configuration.style = style
        return self
    }

    @discardableResult
    public func speed(_ mode: SpeedMode) -> CursorTrail {
        configuration.speedMode = mode
        return self
    }

    @discardableResult
    public func glow(_ config: GlowConfig) -> CursorTrail {
        configuration.glow = config
        return self
    }

    @discardableResult
    public func opacity(_ value: Double) -> CursorTrail {
        configuration.opacity = max(min(value, 1.0), 0.0)
        return self
    }

    // MARK: - Lifecycle

    /// Starts the trail. Must be called on the main thread.
    ///
    /// - Returns: `true` if this call started the trail, `false` if it was already running.
    @discardableResult
    public func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        // Single active trail: a new instance takes over and shuts the previous one down.
        if let previous = CursorTrail.current, previous !== self {
            previous.stop()
        }
        guard !isRunning else { return false }

        let window = TrailWindow(configuration: configuration, screen: Self.screen(containingMouse: true))
        trailWindow = window
        window.orderFrontRegardless()

        // Coordinate space is anchored to the screen the overlay actually covers, so a
        // secondary display gets its own origin and its own flip axis.
        screenFrame = window.screen?.frame ?? window.frame
        lastMouseLocation = Self.localPoint(fromGlobal: NSEvent.mouseLocation, screenFrame: screenFrame)

        startDisplayLink()

        isRunning = true
        CursorTrail.current = self
        return true
    }

    /// Stops the trail. Must be called on the main thread.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning || trailWindow != nil || displayLink != nil else { return }

        stopDisplayLink()
        trailWindow?.orderOut(nil)
        trailWindow = nil
        trailPoints.clear()
        fadeAccumulator = 0
        isRunning = false

        // Only clear the singleton if it is still us — a newer trail may have taken over.
        if CursorTrail.current === self {
            CursorTrail.current = nil
        }
    }

    // MARK: - Coordinates

    /// Converts a global AppKit mouse location into the overlay window's local,
    /// top-left-origin drawing space.
    ///
    /// Global mouse coordinates are bottom-left-origin and span the whole desktop, so a
    /// secondary display is offset by `screenFrame.origin`. The overlay's `NSView` space
    /// is top-left-origin, so y is mirrored about the screen's bottom edge (`maxY`),
    /// not about `NSScreen.main.frame.height` — using the main screen's height put the
    /// trail in the wrong place on any secondary display.
    static func localPoint(fromGlobal point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: point.x - screenFrame.origin.x,
            y: screenFrame.maxY - point.y
        )
    }

    /// The screen the trail overlay should cover: the one under the cursor when there is
    /// one, otherwise the main screen.
    static func screen(containingMouse: Bool) -> NSScreen? {
        guard containingMouse else { return NSScreen.main }
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        stopDisplayLink()

        let context = DisplayLinkContext(trail: self)
        let opaque = Unmanaged.passUnretained(context).toOpaque()

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnError }
            let context = Unmanaged<DisplayLinkContext>.fromOpaque(userInfo).takeUnretainedValue()
            // `withTrail` holds the context's lock and promotes the weak reference to a
            // strong one, so this cannot race with `stopDisplayLink()`.
            context.withTrail { trail in
                DispatchQueue.main.async { [weak trail] in
                    trail?.updateTrail()
                }
            }
            return kCVReturnSuccess
        }

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return
        }
        displayLink = link
        displayLinkContext = context
        CVDisplayLinkSetOutputCallback(link, callback, opaque)
        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        let link = displayLink
        let context = displayLinkContext

        // 1. Stop the link so no further callbacks are delivered.
        if let link {
            CVDisplayLinkStop(link)
        }
        // 2. Close the callback gate. This blocks until any in-flight callback has
        //    returned, then permanently forbids entry. Only now is it safe to drop the
        //    strong reference the unretained `userInfo` pointer relies on.
        context?.markReleased()

        displayLink = nil
        displayLinkContext = nil
    }

    private static func finishTeardown(link: CVDisplayLink?, context: DisplayLinkContext?, window: TrailWindow?) {
        context?.markReleased()
        if let link {
            CVDisplayLinkStop(link)
        }
        window?.orderOut(nil)
    }

    // MARK: - Trail Update

    private static let movementThreshold: CGFloat = 0.5
    static let maxFadeAccumulator: Double = 10.0

    /// Advances the idle fade by one frame's worth of `fadeSpeed`, shedding whole points.
    /// Pure function so the fade arithmetic can be unit-tested without a window.
    ///
    /// `removed` never exceeds `count`, so a fast fade cannot drain more points than the
    /// buffer holds. With an empty buffer there is nothing to shed, so the accumulator is
    /// reset rather than left accumulating dead credit.
    static func idleFadeStep(count: Int, accumulator: Double, fadeSpeed: Double) -> IdleFadeStep {
        guard count > 0 else {
            return IdleFadeStep(removed: 0, accumulator: 0)
        }

        var accumulated = accumulator + fadeSpeed
        var removed = 0
        while accumulated >= 1.0, removed < count {
            removed += 1
            accumulated -= 1.0
        }
        return IdleFadeStep(removed: removed, accumulator: min(accumulated, maxFadeAccumulator))
    }

    private func updateTrail() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return }

        let location = Self.localPoint(fromGlobal: NSEvent.mouseLocation, screenFrame: screenFrame)

        let dx = location.x - lastMouseLocation.x
        let dy = location.y - lastMouseLocation.y
        let isMoving = (dx * dx + dy * dy) > (Self.movementThreshold * Self.movementThreshold)

        if isMoving {
            trailPoints.append(TrailPoint(position: location))
            lastMouseLocation = location
            fadeAccumulator = 0
        } else if !trailPoints.isEmpty {
            let step = Self.idleFadeStep(
                count: trailPoints.count,
                accumulator: fadeAccumulator,
                fadeSpeed: configuration.fadeSpeed
            )
            for _ in 0..<step.removed {
                trailPoints.removeFirst()
            }
            fadeAccumulator = step.accumulator
        }

        if isMoving || !trailPoints.isEmpty {
            trailWindow?.update(trailPoints)
        }
    }
}

/// Bridges the CVDisplayLink callback thread to the trail.
///
/// The link carries an **unretained** pointer to this box, and the box holds the trail
/// **weakly**. That combination is what keeps both ends safe: the trail can never retain
/// itself (so `deinit` is reachable), and a callback can never observe a dead object.
///
/// `withTrail` holds a lock that `stopDisplayLink()` must acquire via `markReleased()`
/// before the box may be released, so callback entry and release cannot overlap.
private final class DisplayLinkContext {
    private weak var trail: CursorTrail?
    private let lock = NSLock()
    private var isReleased = false

    init(trail: CursorTrail) {
        self.trail = trail
    }

    /// Runs `body` with a strong reference to the trail, unless the context has already
    /// been released. Serialised against `markReleased()`.
    func withTrail(_ body: (CursorTrail) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased, let trail else { return }
        // `trail` is a strong local for the whole call, so the object cannot be
        // deallocated underneath `body`.
        body(trail)
    }

    /// Permanently blocks future callbacks and waits for an in-flight one to finish.
    func markReleased() {
        lock.lock()
        isReleased = true
        trail = nil
        lock.unlock()
    }
}
