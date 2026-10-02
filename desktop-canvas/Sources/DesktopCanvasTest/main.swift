import AppKit
import DesktopCanvas

// Smoke test: applies a live Game of Life layout to the desktop, so the canvas
// renders behind the desktop icons. Exercises the real public API
// (`CanvasLayout` + `DesktopCanvas.shared`), and exits nonzero if the layout is
// rejected.

print("=== DesktopCanvas Smoke Test ===")
print("Applying Conway's Game of Life to the desktop...")
print("Look behind your desktop icons for green cells.")
print("Test runs for 5 seconds, then exits.\n")

let screen = NSScreen.main
let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)

let golConfig = GameOfLifeConfig(
    ruleSet: .conway,
    cellSize: 4,
    aliveColor: CodableColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1.0),
    deadColor: CodableColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0),
    marginColor: CodableColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1.0),
    generationsPerSecond: 30
)

let canvas = CanvasModel(
    type: .gameOfLife,
    frame: frame,
    gameOfLifeConfig: golConfig
)

let layout = CanvasLayout(name: "Smoke Test", canvases: [canvas])

switch DesktopCanvas.shared.apply(layout: layout) {
case .ok:
    print("Applied 1 canvas, \(canvas.gameOfLifeConfig?.cellSize ?? 0)pt cells")
case .warning(let message):
    print("WARNING: \(message)")
case .error(let message):
    print("ERROR: \(message)")
    exit(1)
}

// The smoke run needs a running main run loop for the Metal timer and the
// window server to paint.
RunLoop.main.run(until: Date().addingTimeInterval(5))

print("\nTest complete. Stopping...")
DesktopCanvas.shared.stop()
exit(0)