import CursorChanger
import SwiftUI

struct SkinRow: Identifiable {
    let id = UUID()
    let state: CursorState
    let found: Bool
    let detail: String
}

struct ContentView: View {
    @State private var theme: CursorTheme?
    @State private var log: String = "Pick a skin folder, then Apply."
    @State private var autoReapply = false
    @State private var monitor: DisplayChangeMonitor?
    @State private var tickCount = 0

    private var enforcementStatus: String {
        CursorChanger.isEnforcing()
            ? "enforcement ON — \(tickCount) refreshes"
            : "enforcement OFF"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Skin Folder…") { chooseFolder() }
                Spacer()
                Toggle("Reapply on display changes", isOn: $autoReapply)
                    .onChange(of: autoReapply) { newValue in
                        if newValue {
                            startMonitor()
                        } else {
                            monitor?.stop()
                            monitor = nil
                        }
                    }
            }

            Text(theme.map { "Skin: \($0.name) — \($0.cursors.count) state(s) loaded" } ?? "No skin loaded")
                .font(.headline)

            if let theme {
                List {
                    ForEach(rows(for: theme)) { row in
                        HStack {
                            Image(systemName: row.found ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(row.found ? .green : .secondary)
                            Text(row.state.rawValue)
                                .frame(width: 150, alignment: .leading)
                            Text(row.detail)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(maxHeight: .infinity)
            }

            HStack {
                Button("Apply") { apply() }
                    .disabled(theme == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Restore System Defaults") { restore() }
                Button("Refresh Dock + Finder") { refreshShell() }
                Spacer()
                Text(enforcementStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CursorChanger.isEnforcing() ? .green : .secondary)
                    .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                        tickCount = CursorChanger.enforcementReapplies
                    }
            }

            ScrollView {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        }
        .padding(16)
        .frame(width: 640, height: 480)
    }

    private func rows(for theme: CursorTheme) -> [SkinRow] {
        CursorState.allCases.map { state in
            guard let cursor = theme.cursors.first(where: { $0.state == state }) else {
                return SkinRow(state: state, found: false, detail: "system default kept")
            }
            let retina = cursor.retinaFile != nil ? "+2x" : ""
            let hotspot = "hotspot (\(Int(cursor.hotspot.x)),\(Int(cursor.hotspot.y)))"
            let size = "\(Int(cursor.pointSize.width))pt"
            return SkinRow(state: state, found: true, detail: "\(size)\(retina), \(hotspot)")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a skin folder (must contain arrow.png)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                theme = try CursorTheme.load(directory: url)
                log = "Loaded skin '\(theme!.name)' from \(url.path)\n" + log
            } catch {
                theme = nil
                log = "ERROR: \(error.localizedDescription)\n" + log
            }
        }
    }

    private func apply() {
        guard let theme else { return }
        do {
            let report = try CursorChanger.apply(theme: theme)
            if report.isSuccess {
                CursorChanger.startEnforcement(theme: theme)
                log = "[apply] \(report.summary)\n[apply] enforcement ON — keeps registrations alive\n" + log
            } else {
                let failed = report.failures.map { "\($0.cgsName): CGError \($0.error!)" }.joined(separator: "\n  ")
                log = "[apply] FAILURES:\n  \(failed)\n" + log
            }
        } catch {
            log = "[apply] ERROR: \(error.localizedDescription)\n" + log
        }
    }

    private func restore() {
        do {
            CursorChanger.stopEnforcement()
            try CursorChanger.restore()
            log = "[restore] system cursors restored\n" + log
        } catch {
            log = "[restore] ERROR: \(error.localizedDescription)\n" + log
        }
    }

    private func refreshShell() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "/usr/bin/killall Dock 2>/dev/null; /usr/bin/killall Finder 2>/dev/null; true"]
        do {
            try task.run()
            task.waitUntilExit()
            log = "[refresh] Dock and Finder restarting — they will re-request cursors\n" + log
        } catch {
            log = "[refresh] failed: \(error.localizedDescription)\n" + log
        }
    }

    private func startMonitor() {
        let m = DisplayChangeMonitor {
            guard let theme else { return }
            do {
                _ = try CursorChanger.apply(theme: theme)
                log = "[display] reapplied after display change\n" + log
            } catch {
                log = "[display] reapply failed: \(error.localizedDescription)\n" + log
            }
        }
        m.start()
        monitor = m
    }
}

@main
struct CursorChangerDemoApp: App {
    var body: some Scene {
        WindowGroup("CursorChanger") {
            ContentView()
        }
    }
}
