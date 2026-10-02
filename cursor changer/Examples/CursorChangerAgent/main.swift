import AppKit
import CursorChanger
import ApplicationServices

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
    private static let fallbackSkinPaths: [String] = [
        ("~/Desktop/work related/claude/something client mac/polymorph/Examples/Skins/Tuff" as NSString).expandingTildeInPath
    ]
    private var currentTheme: CursorTheme?
    private var mouseMonitors: [Any] = []
    private var lastMoveAssert = Date.distantPast

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let text = "[\(stamp)] \(line)\n"
        let path = "/tmp/cursor-changer-agent.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            try? handle.seekToEnd()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
                apply(theme)
                return
            }
        }
        log("no skin loaded — skinURL invalid and fallback paths missing")
    }

    // MARK: - Coverage monitors

    private var coverage: Coverage {
        Coverage(rawValue: UserDefaults.standard.integer(forKey: Self.coverageKey)) ?? .standard
    }

    private func installMouseMonitors() {
        let clickMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]
        if let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) { [weak self] _ in
            self?.handleClickEvent()
        } {
            mouseMonitors.append(clickMonitor)
        }

        let moveMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        if let moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask) { [weak self] _ in
            self?.handleMoveEvent()
        } {
            mouseMonitors.append(moveMonitor)
        }
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
        UserDefaults.standard.string(forKey: Self.skinPathKey).map { URL(fileURLWithPath: $0) }
    }

    private func apply(_ theme: CursorTheme) {
        do {
            let report = try CursorChanger.apply(theme: theme)
            log("apply '\(theme.name)': \(report.summary)")
            for failure in report.failures {
                log("  FAIL \(failure.cgsName): \(failure.error!.localizedDescription)")
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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log("per-app: no frontmost application")
            return
        }
        guard let theme = currentTheme ?? (skinURL ?? Self.defaultSkinURL()).flatMap({ try? CursorTheme.load(directory: $0) }) else {
            log("per-app: no skin available")
            return
        }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            log("per-app: window list unavailable")
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
            return
        }
        guard let cid = CursorChanger.connectionID(forWindowNumber: windowNumber) else {
            log("per-app: could not resolve connection for window \(windowNumber)")
            return
        }

        log("per-app: registering '\(theme.name)' on \(app.localizedName ?? "?") cid=\(cid)…")
        do {
            let report = try CursorChanger.apply(theme: theme, cid: cid, refresh: false)
            log("per-app result: \(report.summary)")
            for failure in report.failures {
                log("  FAIL \(failure.cgsName): \(failure.error!.localizedDescription)")
            }
            let alert = NSAlert()
            alert.messageText = report.isSuccess
                ? "Skin registered on \(app.localizedName ?? "app") (cid \(cid))"
                : "Registration partially failed on cid \(cid)"
            let selectable = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
            selectable.string = report.summary
            selectable.isEditable = false
            alert.accessoryView = selectable
            alert.runModal()
        } catch {
            log("per-app threw: \(error)")
        }
    }

    @objc private func setCoverage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? Int ?? 1, forKey: Self.coverageKey)
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
        target.terminate()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }
            usleep(200_000)
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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

let app = NSApplication.shared
let delegate = AgentDelegate()
app.delegate = delegate
app.run()
