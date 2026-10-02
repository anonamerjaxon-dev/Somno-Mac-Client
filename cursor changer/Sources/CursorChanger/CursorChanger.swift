import AppKit
import CoreGraphics
import Foundation

public struct ApplyReport {
    public struct Entry {
        public let state: CursorState
        public let cgsName: String
        public let error: Error?
    }

    public let entries: [Entry]

    public var isSuccess: Bool {
        entries.allSatisfy { $0.error == nil }
    }

    public var failures: [Entry] {
        entries.filter { $0.error != nil }
    }

    public var summary: String {
        if isSuccess {
            return "Applied \(entries.count) cursor(s) successfully"
        }
        return "\(entries.count - failures.count)/\(entries.count) applied; \(failures.count) failed: "
            + failures.map { "\($0.state.rawValue) (\(ApplyReport.describe($0.error!)))" }.joined(separator: ", ")
    }

    /// Prefer a real message. Every CursorChanger error type is a
    /// `LocalizedError`, but a `CGError` bridged from the private CGS API is
    /// not, and `localizedDescription` would then degrade to
    /// "The operation couldn't be completed…".
    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

public enum CursorChangerError: Error, CustomStringConvertible, LocalizedError {
    case bridgeUnavailable
    case bridgeLoadFailed(String)
    case restoreFailed(CGError)
    case noStockCapture

    public var description: String {
        switch self {
        case .bridgeUnavailable:
            return "CGS private cursor API unavailable on this macOS version"
        case .bridgeLoadFailed(let reason):
            return "Could not load the CGS cursor API: \(reason)"
        case .restoreFailed(let code):
            return "Restore failed with CGError \(code.rawValue)"
        case .noStockCapture:
            return "No stock capture found — run CursorChangerCLI capture on a clean session (or reboot) first"
        }
    }

    public var errorDescription: String? { description }
}

public struct CursorChangerRegistrationError: Error, CustomStringConvertible, LocalizedError {
    public let code: CGError
    public let name: String?

    public init(code: CGError, name: String? = nil) {
        self.code = code
        self.name = name
    }

    public var description: String {
        if let name {
            return "CGError \(code.rawValue) registering cursor '\(name)'"
        }
        return "CGError \(code.rawValue)"
    }

    public var errorDescription: String? { description }
}

public enum CursorChanger {
    public static let displayNames = ["com.apple.coregraphics.ArrowS", "com.apple.coregraphics.Arrow"]
    public static let coreCursorPrefix = "com.apple.cursor."

    public static var diagnosticLogger: ((String) -> Void)?

    // MARK: - Entry points

    public static func apply(theme: CursorTheme, refresh: Bool = true) throws -> ApplyReport {
        let bridge = try requireBridge()
        return try apply(theme: theme, cid: bridge.mainConnectionID(), refresh: refresh)
    }

    public static func apply(theme: CursorTheme, cid: Int32, refresh: Bool = true) throws -> ApplyReport {
        let bridge = try requireBridge()

        let unregisterErr = bridge.unregisterAll(cid)
        if unregisterErr != .success {
            diagnosticLogger?("apply: CoreCursorUnregisterAll err=\(unregisterErr.rawValue)")
        }
        if cid == bridge.mainConnectionID(), hasStockCapture() {
            let registered = registerStockSet(bridge: bridge, cid: cid, instantly: false, activate: false)
            diagnosticLogger?("apply: stock set re-registered \(registered) cursor(s) (not activated)")
        }

        var entries: [ApplyReport.Entry] = []
        for cursor in theme.cursors {
            entries.append(contentsOf: try register(cursor: cursor, cid: cid, bridge: bridge))
        }

        if cid == bridge.mainConnectionID() {
            show(arrow: true)
            if refresh {
                finalizeRefresh()
            }
        }

        return ApplyReport(entries: entries)
    }

    /// Resolves the WindowServer connection that owns `windowNumber`, so a skin
    /// can be registered on a per-application connection instead of the main one.
    public static func connectionID(forWindowNumber windowNumber: UInt32) -> Int32? {
        guard let bridge = try? requireBridge(),
              let getWindowOwner = bridge.getWindowOwner else { return nil }
        var owner: Int32 = 0
        let err = getWindowOwner(bridge.mainConnectionID(), windowNumber, &owner)
        guard err == .success, owner != 0 else { return nil }
        return owner
    }

    /// Re-asserts the arrow so the just-registered image is what WindowServer
    /// draws immediately.
    ///
    /// - Parameter arrow: when `true` the registered arrow name is activated
    ///   (the normal case). When `false` only the refresh side effects
    ///   (dock override + system-defined cursor reset) run — the parameter is
    ///   no longer ignored.
    @discardableResult
    public static func show(arrow: Bool = true) -> Bool {
        guard let bridge = try? requireBridge() else { return false }
        let cid = bridge.mainConnectionID()
        if arrow, showCursorNamed(displayNames, bridge: bridge, cid: cid) {
            return true
        }
        bridge.setDockCursorOverride(cid, true)
        let err = bridge.setSystemDefinedCursor(cid, 0)
        if err != .success {
            diagnosticLogger?("show(arrow: \(arrow)): setSystemDefinedCursor err=\(err.rawValue)")
        }
        return arrow
    }

    /// `true` when one of `names` was accepted by `CGSSetRegisteredCursor`.
    private static func showCursorNamed(_ names: [String], bridge: CGSBridge, cid: Int32) -> Bool {
        for name in names {
            var seed: Int32 = 0
            let err = name.withCString { cName in
                bridge.setRegisteredCursor(cid, cName, &seed)
            }
            if err == .success {
                return true
            }
            diagnosticLogger?("show: setRegisteredCursor('\(name)') err=\(err.rawValue)")
        }
        return false
    }

    public static let maxCoreCursorSlot = 43

    public static func restore() throws {
        let bridge = try requireBridge()
        let cid = bridge.mainConnectionID()
        let err = bridge.unregisterAll(cid)
        guard err == .success else {
            throw CursorChangerError.restoreFailed(err)
        }
        for slot in 0...maxCoreCursorSlot {
            let slotErr = bridge.setCoreCursor(cid, Int32(slot))
            if slotErr != .success {
                diagnosticLogger?("restore: CoreCursorSet(\(slot)) err=\(slotErr.rawValue)")
            }
        }
        if hasStockCapture() {
            let registered = registerStockSet(bridge: bridge, cid: cid, instantly: true, activate: true)
            diagnosticLogger?("restore: stock set re-registered \(registered) cursor(s)")
        }
        finalizeRefresh()
    }

    public static func nudgeCursorScale(bump: CGFloat = 0.3) throws {
        let bridge = try requireBridge()
        let cid = bridge.mainConnectionID()
        var scale: CGFloat = 1.0
        let getErr = bridge.getCursorScale(cid, &scale)
        let setErr1 = bridge.setCursorScale(cid, scale + bump)
        let setErr2 = bridge.setCursorScale(cid, scale)
        diagnosticLogger?("nudge: scale=\(scale) errs=\(getErr.rawValue),\(setErr1.rawValue),\(setErr2.rawValue)")
    }

    public static func scaleProbe() {
        guard let bridge = try? requireBridge() else { return }
        let cid = bridge.mainConnectionID()
        var scale: CGFloat = 1.0
        let getErr = bridge.getCursorScale(cid, &scale)
        diagnosticLogger?("probe: get err=\(getErr.rawValue) scale=\(scale)")
        let original = (getErr == .success && scale.isFinite && scale > 0) ? scale : 1.0
        let e1 = bridge.setCursorScale(cid, 2.0)
        diagnosticLogger?("probe: set 2.0 err=\(e1.rawValue)")
        usleep(120_000)
        var verify: CGFloat = -1
        let vErr = bridge.getCursorScale(cid, &verify)
        diagnosticLogger?("probe: verify err=\(vErr.rawValue) scale=\(verify)")
        let e2 = bridge.setCursorScale(cid, original)
        diagnosticLogger?("probe: restore \(original) err=\(e2.rawValue)")
    }

    /// Forces WindowServer to re-resolve every cursor: dock override, a
    /// cursor-scale bump (set then immediately restore), and the
    /// system-defined cursor reset.
    public static func finalizeRefresh(scaleBump: CGFloat = 0.1) {
        guard let bridge = try? requireBridge() else { return }
        let cid = bridge.mainConnectionID()
        bridge.setDockCursorOverride(cid, true)
        diagnosticLogger?("finalize: dockOverride called (void ABI)")
        var scale: CGFloat = 1.0
        if bridge.getCursorScale(cid, &scale) == .success, scale.isFinite, scale > 0 {
            let e1 = bridge.setCursorScale(cid, scale + scaleBump)
            let e2 = bridge.setCursorScale(cid, scale)
            diagnosticLogger?("finalize: scale get=\(scale) set errs=\(e1.rawValue),\(e2.rawValue)")
        } else {
            let e1 = bridge.setCursorScale(cid, 1.0 + scaleBump)
            let e2 = bridge.setCursorScale(cid, 1.0)
            diagnosticLogger?("finalize: scale get FAILED, blind set errs=\(e1.rawValue),\(e2.rawValue)")
        }
        let sysErr = bridge.setSystemDefinedCursor(cid, 0)
        diagnosticLogger?("finalize: setSystemDefinedCursor(0) err=\(sysErr.rawValue)")
    }

    /// Full re-assertion: re-registers the enforced skin (when one is set) and
    /// repeats *every* activation step that apply performs —
    /// `CGSRegisterCursorWithImages`, `CGSSetRegisteredCursor`,
    /// `CoreCursorSet`, and the scale-bump refresh.
    ///
    /// The enforcement tick used to stop at re-registration, which is why the
    /// system cursor kept winning: the image was in WindowServer memory but
    /// nothing ever put it back in front.
    public static func reassert() {
        guard let bridge = try? requireBridge() else { return }
        enforce(bridge: bridge, cid: bridge.mainConnectionID())
    }

    // MARK: - Enforcement

    /// A registration that can be replayed verbatim on every enforcement tick.
    struct EnforcedRegistration {
        let names: [String]
        let pointSize: CGSize
        let hotspot: CGPoint
        let images: [CGImage]
    }

    private static let stateLock = NSLock()
    private static var _enforcementTimer: Timer?
    private static var _enforcedTheme: CursorTheme?
    private static var _enforcementCount = 0
    private static var _enforcedRegistrations: [EnforcedRegistration] = []

    private static func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    static func coreSlot(for name: String) -> Int32? {
        guard name.hasPrefix(coreCursorPrefix) else { return nil }
        return Int32(name.dropFirst(coreCursorPrefix.count))
    }

    /// Decodes every image in the theme once, up front, so the timer never does
    /// file I/O or rasterization.
    static func loadEnforcedRegistrations(from theme: CursorTheme) -> [EnforcedRegistration] {
        var result: [EnforcedRegistration] = []
        for cursor in theme.cursors {
            guard let images = try? ThemeImageLoader.cgImages(
                oneXURL: cursor.imageFile,
                retinaURL: cursor.retinaFile,
                pointSize: cursor.pointSize
            ) else {
                diagnosticLogger?("enforce: skipping '\(cursor.state.rawValue)' — image load failed")
                continue
            }
            result.append(EnforcedRegistration(
                names: cursor.state.cgsNames,
                pointSize: cursor.pointSize,
                hotspot: cursor.hotspot,
                images: images
            ))
        }
        return result
    }

    private static var enforcedRegistrations: [EnforcedRegistration] {
        withStateLock { _enforcedRegistrations }
    }

    private static var hasEnforcedTheme: Bool {
        withStateLock { _enforcedTheme != nil }
    }

    private static func bumpEnforcementCount() {
        withStateLock { _enforcementCount += 1 }
    }

    /// One enforcement tick: re-register, re-activate, re-refresh.
    static func enforce(bridge: CGSBridge, cid: Int32) {
        let registrations = enforcedRegistrations
        for registration in registrations {
            registerImages(registration, bridge: bridge, cid: cid)
            activateNames(registration.names, bridge: bridge, cid: cid)
        }
        if registrations.isEmpty {
            activateNames(displayNames, bridge: bridge, cid: cid)
        }
        bridge.setDockCursorOverride(cid, true)
        let sysErr = bridge.setSystemDefinedCursor(cid, 0)
        if sysErr != .success {
            diagnosticLogger?("enforce: setSystemDefinedCursor(0) err=\(sysErr.rawValue)")
        }
        bumpCursorScale(bridge: bridge, cid: cid, by: 0.1)
    }

    /// `CGSRegisterCursorWithImages` — captured and logged, never discarded.
    private static func registerImages(_ registration: EnforcedRegistration, bridge: CGSBridge, cid: Int32) {
        for name in registration.names {
            var seed: Int32 = 0
            let err = name.withCString { cName in
                bridge.registerCursorWithImages(
                    cid,
                    cName,
                    true,
                    true,
                    registration.pointSize,
                    registration.hotspot,
                    registration.images.count,
                    0,
                    registration.images as CFArray,
                    &seed
                )
            }
            if err != .success {
                diagnosticLogger?("enforce: registerCursorWithImages('\(name)') err=\(err.rawValue)")
            }
        }
    }

    /// `CGSSetRegisteredCursor` + `CoreCursorSet` — the activation steps that
    /// apply used to do exactly once.
    static func activateNames(_ names: [String], bridge: CGSBridge, cid: Int32) {
        for name in names {
            var activateSeed: Int32 = 0
            let setErr = name.withCString { cName in
                bridge.setRegisteredCursor(cid, cName, &activateSeed)
            }
            if setErr != .success {
                diagnosticLogger?("enforce: setRegisteredCursor('\(name)') err=\(setErr.rawValue)")
            }
            guard let slot = coreSlot(for: name) else { continue }
            let coreErr = bridge.setCoreCursor(cid, slot)
            if coreErr != .success {
                diagnosticLogger?("enforce: CoreCursorSet(\(name) -> \(slot)) err=\(coreErr.rawValue)")
            }
        }
    }

    private static func bumpCursorScale(bridge: CGSBridge, cid: Int32, by bump: CGFloat) {
        var scale: CGFloat = 1.0
        if bridge.getCursorScale(cid, &scale) == .success, scale.isFinite, scale > 0 {
            let e1 = bridge.setCursorScale(cid, scale + bump)
            let e2 = bridge.setCursorScale(cid, scale)
            diagnosticLogger?("enforce: scale \(scale) -> \(scale + bump) -> \(scale) errs=\(e1.rawValue),\(e2.rawValue)")
        } else {
            let e1 = bridge.setCursorScale(cid, 1.0 + bump)
            let e2 = bridge.setCursorScale(cid, 1.0)
            diagnosticLogger?("enforce: blind scale bump errs=\(e1.rawValue),\(e2.rawValue)")
        }
    }

    public static func startEnforcement(theme: CursorTheme, interval: TimeInterval = 1.5) {
        stopEnforcement()
        let registrations = loadEnforcedRegistrations(from: theme)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            guard hasEnforcedTheme else { return }
            bumpEnforcementCount()
            guard let bridge = try? requireBridge() else { return }
            enforce(bridge: bridge, cid: bridge.mainConnectionID())
        }
        RunLoop.main.add(timer, forMode: .common)
        withStateLock {
            _enforcedTheme = theme
            _enforcedRegistrations = registrations
            _enforcementTimer = timer
        }
        diagnosticLogger?("enforce: started, \(registrations.count) state(s) at \(interval)s interval")
    }

    public static func stopEnforcement() {
        let timer: Timer? = withStateLock {
            let previous = _enforcementTimer
            _enforcementTimer = nil
            _enforcedTheme = nil
            _enforcementCount = 0
            // Drop the decoded CGImages too — otherwise a stopped enforcement
            // still pins one bitmap per state for the life of the process.
            _enforcedRegistrations = []
            return previous
        }
        timer?.invalidate()
    }

    public static func isEnforcing() -> Bool {
        withStateLock { _enforcementTimer != nil }
    }

    public static var enforcementReapplies: Int {
        withStateLock { _enforcementCount }
    }

    // MARK: - Registration

    private static func register(cursor: ResolvedCursor, cid: Int32, bridge: CGSBridge) throws -> [ApplyReport.Entry] {
        let images = try ThemeImageLoader.cgImages(
            oneXURL: cursor.imageFile,
            retinaURL: cursor.retinaFile,
            pointSize: cursor.pointSize
        )
        return cursor.state.cgsNames.map { name in
            var seed: Int32 = 0
            let err = name.withCString { cName in
                bridge.registerCursorWithImages(
                    cid,
                    cName,
                    true,
                    true,
                    cursor.pointSize,
                    cursor.hotspot,
                    images.count,
                    0,
                    images as CFArray,
                    &seed
                )
            }
            guard err == .success else {
                diagnosticLogger?("apply: registerCursorWithImages('\(name)') err=\(err.rawValue)")
                return ApplyReport.Entry(
                    state: cursor.state,
                    cgsName: name,
                    error: CursorChangerRegistrationError(code: err, name: name)
                )
            }
            var activateSeed: Int32 = 0
            let setErr = name.withCString { cName in
                bridge.setRegisteredCursor(cid, cName, &activateSeed)
            }
            if setErr != .success {
                diagnosticLogger?("apply: setRegisteredCursor('\(name)') err=\(setErr.rawValue)")
            }
            if let slot = coreSlot(for: name) {
                let coreErr = bridge.setCoreCursor(cid, slot)
                if coreErr != .success {
                    diagnosticLogger?("apply: CoreCursorSet('\(name)' -> \(slot)) err=\(coreErr.rawValue)")
                }
            }
            return ApplyReport.Entry(state: cursor.state, cgsName: name, error: nil)
        }
    }

    // MARK: - Bridge access

    /// Fails with a real message instead of trapping.
    static func requireBridge() throws -> CGSBridge {
        guard CGSBridge.isAvailable() else {
            if let reason = CGSBridge.lastLoadError.map(String.init(describing:)) {
                throw CursorChangerError.bridgeLoadFailed(reason)
            }
            throw CursorChangerError.bridgeUnavailable
        }
        return try CGSBridge.shared
    }

    /// A human-readable explanation of why the CGS bridge cannot be used, or
    /// `nil` when it works. Used by the CLI/agent to print something better
    /// than a bare "unavailable", and by the test suite to prove the M1 fix
    /// (no `try!` trap on any reachable path).
    public static func requireBridgeErrorDescription() -> String? {
        do {
            _ = try requireBridge()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}