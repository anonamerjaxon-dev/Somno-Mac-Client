import AppKit

final class ScreenManager {
    private(set) var windows: [NSScreen: CanvasWindow] = [:]
    private var layout: CanvasLayout?
    private var displayObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applyEmbedded(layout: CanvasLayout) {
        self.layout = layout

        for screen in NSScreen.screens {
            createWindow(for: screen)
        }

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }

        let workspace = NSWorkspace.shared.notificationCenter

        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            for (_, window) in self?.windows ?? [:] {
                window.pauseAllProviders()
            }
        }

        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for (_, window) in self.windows {
                window.reorderToDesktop()
                window.resumeAllProviders()
            }
        }
    }

    func stop() {
        if let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        for (_, window) in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    func provider<T>(for canvasID: UUID, as type: T.Type) -> T? {
        for (_, window) in windows {
            if let provider = window.provider(for: canvasID, as: type) {
                return provider
            }
        }
        return nil
    }

    func gameOfLifeProviders() -> [GameOfLifeProvider] {
        windows.values.flatMap { $0.gameOfLifeProviders() }
    }

    func refresh(with layout: CanvasLayout? = nil) {
        if let layout { self.layout = layout }
        guard let layout = self.layout else { return }
        let background = layout.backgroundColor?.nsColor
        for (_, window) in windows {
            window.setBackgroundColor(background)
            window.layoutCanvases(layout.canvases)
        }
    }

    private func createWindow(for screen: NSScreen) {
        guard let layout = layout else { return }
        let window = CanvasWindow(screen: screen)
        window.setBackgroundColor(layout.backgroundColor?.nsColor)
        window.layoutCanvases(ScreenGeometry.canvasesVisible(on: screen.frame, in: layout.canvases))
        windows[screen] = window
    }

    private func handleScreenChange() {
        let currentScreens = NSScreen.screens

        // A screen can be re-configured (resolution, scale, arrangement) without
        // being removed, so surviving windows are re-framed against their new
        // frame and re-laid-out instead of keeping stale geometry.
        for (screen, window) in windows {
            if currentScreens.contains(screen) {
                window.reframe(to: screen.frame)
            } else {
                window.orderOut(nil)
                windows[screen] = nil
            }
        }

        for screen in currentScreens where windows[screen] == nil {
            createWindow(for: screen)
        }

        refresh()
    }
}