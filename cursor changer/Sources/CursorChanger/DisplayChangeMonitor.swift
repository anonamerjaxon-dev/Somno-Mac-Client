import CoreGraphics
import Foundation

private let beginConfigurationBit: UInt32 = 1 << 0

private func cursorChangerDisplayReconfiguration(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // `passRetained` (set in `start`) keeps the monitor alive for exactly as
    // long as it is registered; `takeUnretainedValue` here balances it with the
    // matching `release()` in `stop`. The old `passUnretained` stored an
    // unowned pointer, so any reconfiguration callback delivered after the
    // object was released read freed memory.
    let monitor = Unmanaged<DisplayChangeMonitor>.fromOpaque(userInfo).takeRetainedValue()
    let isBeginPass = flags.rawValue & beginConfigurationBit != 0 || flags.rawValue == 0
    if !isBeginPass {
        // Hop to the main run loop: `handler` reaches AppKit + CGS, and the
        // callback may arrive on any thread.
        DispatchQueue.main.async {
            monitor.handler()
        }
        monitor.registered = false
    }
}

public final class DisplayChangeMonitor {
    /// Registration state, guarded by `lock`. The callback runs on a Core
    /// Graphics thread, so `registered` is touched from two threads.
    private let lock = NSLock()
    private var _registered = false

    var registered: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _registered
        }
        set {
            lock.lock()
            _registered = newValue
            lock.unlock()
        }
    }

    let handler: () -> Void

    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        guard !registered else { return }
        let opaque = Unmanaged.passRetained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(cursorChangerDisplayReconfiguration, opaque)
        if result == .success {
            registered = true
        } else {
            Unmanaged<DisplayChangeMonitor>.fromOpaque(opaque).release()
        }
    }

    public func stop() {
        guard registered else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(cursorChangerDisplayReconfiguration, opaque)
        registered = false
        // Balances the `passRetained` in `start`. Safe because `stop` returns
        // early (leaving the reference intact) unless we actually registered.
        Unmanaged<DisplayChangeMonitor>.fromOpaque(opaque).release()
    }
}