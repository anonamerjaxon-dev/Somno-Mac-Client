import AppKit
import ApplicationServices
import CursorChanger

enum Coverage: Int {
    case gentle = 0
    case standard = 1
    case continuous = 2

    var label: String {
        switch self {
        case .gentle: return "Gentle (app switches only)"
        case .standard: return "Standard (clicks too)"
        case .continuous: return "Continuous (every mouse move)"
        }
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private static let skinPathKey = "skinPath"
    private static let coverageKey = "coverage"
    private static let skinPathOverrideKey = "CURSOR_CHANGER_SKIN"
    private static let logPath = "/tmp/cursor-changer-agent.log"

    private var currentTheme: CursorTheme?
    private var mouseMonitors: [Any] = []
    private var lastMoveAssert = Date.distantPast

    // MARK: - Skin discovery (H3)

    /// Candidate skin folders, in priority order.
    ///
    /// The old code hard-coded an absolute path into a folder that no longer
    /// exists, so a fresh install silently started with no skin at all. Now:
    ///   1. `CURSOR_CHANGER_SKIN` environment variable (explicit override)
    ///   2. the user's saved choice in UserDefaults
    ///   3. paths derived from this executable's location (works from
    ///      `.build/debug`, from a copied binary, and from a Login Item)
    private static var fallbackSkinPaths: [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment[skinPathOverrideKey], !override.isEmpty {
            paths.append((override as NSString).expandingTildeInPath)
        }
        if let saved = UserDefaults.standard.string(forKey: skinPathKey) {
            paths.append((saved as NSString).expandingTildeInPath)
        }
        paths.append(contentsOf: executableRelativeSkinPaths())
        return paths
    }

    /// Walks up from the executable looking for the bundled demo skin. Works
    /// whichever way the binary was launched:
    ///   `.build/debug/CursorChangerAgent` → `<pkg>/Examples/Skins/Tuff`
    ///   `/Applications/CursorChanger.app/Contents/MacOS/CursorChangerAgent`
    ///   → `<repo>/Examples/Skins/Tuff`
    private static func executableRelativeSkinPaths() -> [String] {
        var candidates: [URL] = []
        let fm = FileManager.default
        var roots: [URL] = []
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent())          // .build/debug
            roots.append(executable.deletingLastPathComponent().deletingLastPathComponent()) // .build
            roots.append(executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) // package root
        }
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
        }
        var current = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<4 {
            roots.append(current)
            current = current.deletingLastPathComponent()
        }
        for root in roots {
            candidates.append(root.appendingPathComponent("Examples/Skins/Tuff"))
            candidates.append(root.appendingPathComponent("Skins/Tuff"))
            candidates.append(root.appendingPathComponent("Examples/CursorChangerAgent/../../Skins/Tuff").standardizedFileURL)
        }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return candidates
            .map { $0.standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
    }

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let text = "[\(stamp)] \(line)\n"
        let path = Self.logPath
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("agent launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        CursorChanger.diagnosticLogger = { [weak self] line in
            self?.log(line)
        }
        rebuildMenu()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.currentTheme != nil else { return }
            CursorChanger.finalizeRefresh()
            self?.log("activation -> finalizeRefresh")
        }

        loadAndApplySkin()

        // H2: these were never installed, so the whole Coverage feature (and the
        // click/move reassert handlers) was dead code.
        installMouseMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMouseMonitors()
        CursorChanger.stopEnforcement()
        try? CursorChanger.restore()
    }

    private func loadAndApplySkin() {
        if let url = skinURL, let theme = try? CursorTheme.load(directory: url) {
            apply(theme)
            return
        }
        for path in Self.fallbackSkinPaths {
            if let theme = try? CursorTheme.load(directory: URL(fileURLWithPath: path)) {
                log("auto-discovered skin at \(path)")
                apply(theme)
                return
            }
        }
        log("no skin loaded — check \(Self.logPath); skinURL invalid and no fallback path exists")
        log("tried: \(Self.fallbackSkinPaths.joined(separator: ", "))")
    }

    // MARK: - Coverage monitors

    private var coverage: Coverage {
        // `UserDefaults.integer(forKey:)` returns 0 for an ABSENT key, which
        // is exactly `Coverage.gentle` — so the documented `.standard` default
        // never applied on a fresh install. `object(forKey:)` distinguishes
        // "never set" from "set to 0".
        guard let stored = UserDefaults.standard.object(forKey: Self.coverageKey) as? Int else {
            return .standard
        }
        return Coverage(rawValue: stored) ?? .standard
    }

    /// Global event monitors only fire for an app with Accessibility
    /// permission. Without it, `addGlobalMonitorForEvents` returns nil and the
    /// Coverage setting would silently do nothing — so say so out loud.
    private func installMouseMonitors() {
        guard AXIsProcessTrusted() else {
            log("global mouse monitors NOT installed — grant Accessibility permission to \(ProcessInfo.processInfo.processIdentifier) for Coverage=Standard/Continuous")
            NSApp.presentErrorSheetIfPossible(
                "Coverage needs Accessibility permission",
                detail: "Add CursorChanger Agent in System Settings ▸ Privacy & Security ▸ Accessibility, then relaunch. Until then the skin still applies, but it is only re-asserted on app switch."
            )
            rebuildMenu()
            return
        }
        let clickMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]
        if let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] _ in
            self?.handleClickEvent()
        }) {
            mouseMonitors.append(clickMonitor)
        } else {
            log("click monitor could not be installed")
        }

        let moveMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        if let moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            self?.handleMoveEvent()
        }) {
            mouseMonitors.append(moveMonitor)
        } else {
            log("move monitor could not be installed")
        }
        log("mouse monitors installed (\(mouseMonitors.count)) coverage=\(coverage.label)")
    }

    private func removeMouseMonitors() {
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors.removeAll()
    }

    private func handleClickEvent() {
        guard currentTheme != nil, coverage.rawValue >= Coverage.standard.rawValue else { return }
        CursorChanger.reassert()
    }

    private func handleMoveEvent() {
        guard currentTheme != nil, coverage == .continuous else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMoveAssert) >= 0.08 else { return }
        lastMoveAssert = now
        CursorChanger.reassert()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        // `isEnabled` on an item is only honoured when auto-enabling is off;
        // leaving the default (true) made the "Reapply Skin" item permanently
        // greyed out even with a valid skin.
        menu.autoenablesItems = false

        let title = NSMenuItem()
        title.title = currentTheme.map { "CursorChanger — \($0.name) active" }
            ?? (skinURL != nil ? "CursorChanger — skin failed to load" : "CursorChanger — no skin found")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let choose = NSMenuItem(title: "Choose Skin…", action: #selector(chooseSkin), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let applyItem = NSMenuItem(title: "Reapply Skin", action: #selector(applySelected), keyEquivalent: "a")
        applyItem.target = self
        applyItem.isEnabled = skinURL != nil
        menu.addItem(applyItem)

        // H2: `applyToFrontmost` was implemented but wired to nothing.
        let frontmostItem = NSMenuItem(
            title: "Apply Skin to Frontmost App…",
            action: #selector(applyToFrontmost),
            keyEquivalent: "f"
        )
        frontmostItem.target = self
        frontmostItem.isEnabled = currentTheme != nil
        menu.addItem(frontmostItem)

        let restoreItem = NSMenuItem(title: "Restore Stock Cursors", action: #selector(restoreStock), keyEquivalent: "r")
        restoreItem.target = self
        menu.addItem(restoreItem)

        let nudgeItem = NSMenuItem(title: "Nudge Cursor Now (test)", action: #selector(nudgeCursor), keyEquivalent: "n")
        nudgeItem.target = self
        menu.addItem(nudgeItem)

        menu.addItem(.separator())

        let coverageTitle = NSMenuItem(title: "Coverage", action: nil, keyEquivalent: "")
        coverageTitle.isEnabled = false
        menu.addItem(coverageTitle)
        for mode in [Coverage.gentle, .standard, .continuous] {
            let item = NSMenuItem(title: mode.label, action: #selector(setCoverage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = coverage == mode ? .on : .off
            menu.addItem(item)
        }
        let coverageNote = NSMenuItem(title: "  (needs Accessibility permission)", action: nil, keyEquivalent: "")
        coverageNote.isEnabled = false
        menu.addItem(coverageNote)

        menu.addItem(.separator())

        let relaunchTitle = NSMenuItem(title: "Relaunch App with Skin", action: nil, keyEquivalent: "")
        relaunchTitle.isEnabled = false
        menu.addItem(relaunchTitle)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running.prefix(15) {
            let item = NSMenuItem(
                title: app.localizedName ?? app.bundleURL?.lastPathComponent ?? "?",
                action: #selector(relaunchApp(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = app.bundleURL
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: loginItemEnabled ? "Launch at Login ✓ (click to remove)" : "Launch at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit (restores stock)", action: #selector(quitAgent), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.title = currentTheme != nil ? "◆" : "◇"
    }

    // MARK: - Actions

    private var skinURL: URL? {
        UserDefaults.standard.string(forKey: Self.skinPathKey).map { CursorTheme.expandSkinPath($0) }
    }

    private func apply(_ theme: CursorTheme) {
        do {
            let report = try CursorChanger.apply(theme: theme)
            log("apply '\(theme.name)': \(report.summary)")
            for failure in report.failures {
                log("  FAIL \(failure.cgsName): \(failure.error?.localizedDescription ?? "unknown")")
            }
            guard report.isSuccess else {
                currentTheme = theme
                rebuildMenu()
                return
            }
            currentTheme = theme
            UserDefaults.standard.set(theme.directory.path, forKey: Self.skinPathKey)
            CursorChanger.startEnforcement(theme: theme)
            forceVisualRefresh()
        } catch {
            log("apply threw: \(error)")
            NSApp.presentError(error)
        }
    }

    private func forceVisualRefresh() {
        let location = NSEvent.mouseLocation
        let window = NSWindow(
            contentRect: NSRect(origin: location, size: NSSize(width: 1, height: 1)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
            window?.close()
        }
        CursorChanger.finalizeRefresh()
    }

    @objc private func chooseSkin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Pick a skin folder (must contain arrow.png or arrow.svg)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let theme = try? CursorTheme.load(directory: url) else {
            let alert = NSAlert()
            alert.messageText = "Not a valid skin folder"
            alert.informativeText = "A skin needs arrow.png (or .svg) plus any other cursor images, and an optional theme.json."
            alert.runModal()
            return
        }
        apply(theme)
        rebuildMenu()
    }

    @objc private func applySelected() {
        guard let url = skinURL, let theme = try? CursorTheme.load(directory: url) else { return }
        apply(theme)
        rebuildMenu()
    }

    @objc private func restoreStock() {
        removeMouseMonitors()
        CursorChanger.stopEnforcement()
        try? CursorChanger.restore()
        CursorChanger.finalizeRefresh()
        currentTheme = nil
        rebuildMenu()
    }

    @objc private func nudgeCursor() {
        CursorChanger.scaleProbe()
        rebuildMenu()
    }

    @objc private func applyToFrontmost() {
        // The per-window path needs Screen Recording permission to read
        // `CGWindowListCopyWindowInfo` window numbers reliably; without it the
        // list comes back without usable IDs. Explain rather than fail silently.
        guard currentTheme != nil else {
            presentHint("No skin applied yet", detail: "Choose a skin first.")
            return
        }
        let theme = currentTheme!
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log("per-app: no frontmost application")
            presentHint("No frontmost app", detail: "Switch to the app you want to theme, then try again.")
            return
        }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            log("per-app: window list unavailable")
            presentHint("Could not read the window list", detail: "Grant Screen Recording permission in System Settings ▸ Privacy & Security, then try again.")
            return
        }
        var windowNumber: UInt32?
        for w in list where (w[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) {
            if (w[kCGWindowLayer as String] as? Int) == 0 {
                windowNumber = w[kCGWindowNumber as String] as? UInt32
                break
            }
        }
        guard let windowNumber else {
            log("per-app: \(app.localizedName ?? "?") has no on-screen layer-0 window")
            presentHint("No window found", detail: "\(app.localizedName ?? "That app") has no on-screen window to theme.")
            return
        }
        guard let cid = CursorChanger.connectionID(forWindowNumber: windowNumber) else {
            log("per-app: could not resolve connection for window \(windowNumber)")
            presentHint("Could not resolve the window's connection", detail: "The app may be using a private window server connection.")
            return
        }

        log("per-app: registering '\(theme.name)' on \(app.localizedName ?? "?") cid=\(cid)…")
        do {
            let report = try CursorChanger.apply(theme: theme, cid: cid, refresh: false)
            log("per-app result: \(report.summary)")
            for failure in report.failures {
                log("  FAIL \(failure.cgsName): \(failure.error?.localizedDescription ?? "unknown")")
            }
            let alert = NSAlert()
            alert.messageText = report.isSuccess
                ? "Skin registered on \(app.localizedName ?? "app") (cid \(cid))"
                : "Registration partially failed on cid \(cid)"
            alert.informativeText = "Enforcement keeps re-asserting the skin; this per-connection registration is the extra step for apps that override cursors themselves."
            let selectable = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
            selectable.string = report.summary
            selectable.isEditable = false
            alert.accessoryView = selectable
            alert.runModal()
        } catch {
            log("per-app threw: \(error)")
            presentHint("Registration failed", detail: error.localizedDescription)
        }
    }

    /// Status-bar apps have no window to attach a sheet to, so a modal alert
    /// is the honest way to surface a permission problem.
    private func presentHint(_ message: String, detail: String) {
        log("hint: \(message) — \(detail)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func setCoverage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? Int ?? Coverage.standard.rawValue, forKey: Self.coverageKey)
        // Monitors are gated on Accessibility, so retry the install now that
        // the user may have just granted it in System Settings.
        removeMouseMonitors()
        installMouseMonitors()
        rebuildMenu()
    }

    private static func defaultSkinURL() -> URL? {
        fallbackSkinPaths.first.map { URL(fileURLWithPath: $0) }
    }

    @objc private func relaunchApp(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let target = NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }
        guard let target else { return }
        let pid = target.processIdentifier
        let bundleURL = url
        target.terminate()
        // The old loop blocked the main run loop for up to 8 seconds, freezing
        // the status-bar menu and every AppKit timer (including enforcement).
        // Poll asynchronously instead, then reopen.
        let deadline = Date().addingTimeInterval(8)
        func waitThenOpen() {
            if Date() >= deadline || kill(pid, 0) != 0 {
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitThenOpen() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitThenOpen() }
    }

    @objc private func quitAgent() {
        NSApp.terminate(nil)
    }

    // MARK: - Login item

    private var launchAgentURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/com.cursor-changer.agent.plist")
    }

    private var loginItemEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLoginItem() {
        if loginItemEnabled {
            try? FileManager.default.removeItem(at: launchAgentURL)
            runLaunchctl(["unload", launchAgentURL.path])
        } else {
            guard let executable = Bundle.main.executableURL?.path else { return }
            let plist: [String: Any] = [
                "Label": "com.cursor-changer.agent",
                "ProgramArguments": [executable],
                "RunAtLoad": true
            ]
            try? FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: launchAgentURL)
            }
            runLaunchctl(["load", launchAgentURL.path])
        }
        rebuildMenu()
    }

    private func runLaunchctl(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        try? task.run()
        task.waitUntilExit()
    }
}

/// Small shim so permission problems can be surfaced as an alert even when the
/// agent is running as an accessory (no window to present a sheet on).
private extension NSApplication {
    func presentErrorSheetIfPossible(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AgentDelegate()
app.delegate = delegate
app.run()