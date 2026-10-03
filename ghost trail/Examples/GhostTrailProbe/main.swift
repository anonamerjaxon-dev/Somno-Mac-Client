// GhostTrail probe: proves a trail actually reaches the screen.
//
// This lives in the repo on purpose. "The trail doesn't show up" is the one bug
// a unit test cannot catch: it needs a real window server, a real event tap, and
// real pixels. Everything else about GhostTrail is covered by 35 assertions in
// Tests/GhostTrailTests; this is the rest.
//
// Two facts about the library shape this harness, both learned the hard way:
//
//   1. The window being trailed must live in a SEPARATE process. GhostTrail
//      skips windows owned by its own PID so the overlay never trails itself,
//      so a single-process probe always reports zero trails and looks broken.
//   2. The parent must SPIN ITS MAIN RUN LOOP. GhostTrail drives everything from
//      a display link installed on `.main`; a parent that `Thread.sleep`s never
//      runs the run loop, so the poll never happens and no trail ever appears.
//
//   swift run GhostTrailProbe                     # overlay + child window + screenshots
//   swift run GhostTrailProbe --window            # the child alone, for debugging
//   swift run GhostTrailProbe --level             # the child's window level, for debugging
import AppKit
import GhostTrail

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func screenShot(to path: String) -> Bool {
    guard let screen = NSScreen.screens.first,
          let displayID = screen.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let image = CGDisplayCreateImage(
              displayID,
              rect: CGRect(x: 0, y: 0,
                           width: screen.frame.width,
                           height: screen.frame.height))
    else { return false }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    try? data.write(to: URL(fileURLWithPath: path))
    return true
}

/// `CGEvent.location` is in *Quartz* global coordinates: top-left of the main
/// display, `+y` pointing DOWN. `NSWindow.frame` is Cocoa: bottom-left, `+y` up.
/// Posting an event with a Cocoa point lands the press wherever that number
/// happens to be, which is nowhere near the window — the tap records the press,
/// hit-tests nothing, and no trail ever appears. Convert once, here.
func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
    let screen = NSScreen.screens.first ?? NSScreen.main!
    return CGPoint(x: point.x, y: screen.frame.maxY - point.y)
}

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// The child drags along a fixed band, so the expected ribbon position is
/// known in Quartz coordinates and the screenshot can be checked numerically.
///
/// The band must avoid every window already on screen. GhostTrail erases ribbon
/// pixels that fall under a normal or floating window — that is the whole point,
/// it is how the trail appears to pass behind — so dragging across a window is a
/// *correct* run that produces no visible ribbon at all, and the probe then
/// proves nothing. The parent finds bare desktop and hands the start point down.
///
/// The drag is deliberately SHORT. The swept band is
/// `(offset + windowSize).width × (offset + windowSize).height` = 900×380pt, and
/// a screen with several windows open rarely has 900pt of clear desktop. The
/// ribbon's length comes from `frameCount` samples, not from the distance
/// travelled, so a shorter drag still produces a ribbon — it just has fewer
/// sections. The default of 900pt was found the honest way: the first run of
/// this harness reported "no bare desktop", which was the harness refusing to
/// test, not the library failing.
let startCocoaFile = "/tmp/gt-probe-start"
let endCocoaOffset = CGPoint(x: 220, y: 60)
let windowSize = CGSize(width: 420, height: 260)

func dragBandQuartz(from start: CGPoint) -> CGRect {
    let screen = NSScreen.screens.first ?? NSScreen.main!
    let end = CGPoint(x: start.x + endCocoaOffset.x, y: start.y + endCocoaOffset.y)
    let minX = min(start.x, end.x)
    let maxX = max(start.x, end.x) + windowSize.width
    let minCocoaY = min(start.y, end.y)
    let maxCocoaY = max(start.y, end.y) + windowSize.height
    return CGRect(x: minX,
                  y: screen.frame.maxY - maxCocoaY,
                  width: maxX - minX,
                  height: maxCocoaY - minCocoaY)
}

/// A start point whose whole drag band clears every window on screen.
///
/// Searches a coarse grid for the position with the most uncovered band, and
/// requires at least `minClearance` of the band to be free — a partially
/// covered band still proves something (the ribbon shows in the gaps) but is a
/// weaker test, so it is only accepted as a last resort and reported as such.
func findBareDesktopStart() -> (point: CGPoint, clearance: CGFloat)? {
    let screen = NSScreen.screens.first!
    let blockers = visibleWindowFrames()

    let band = dragBandQuartz(from: .zero)
    var best: (score: CGFloat, point: CGPoint)?
    for x in stride(from: CGFloat(20), through: screen.frame.width - band.width - 20, by: 40) {
        for y in stride(from: CGFloat(20), through: screen.frame.height - band.height - 20, by: 40) {
            let candidate = CGPoint(x: x, y: y)
            let rect = dragBandQuartz(from: candidate)
            let covered = blockers.reduce(CGFloat(0)) { $0 + $1.intersection(rect).area }
            let free = rect.area - covered
            guard free > 0 else { continue }
            if best == nil || free > best!.score { best = (free, candidate) }
        }
    }
    guard let best else { return nil }
    return (best.point, best.score / band.area)
}

/// Frames of the normal and floating windows on screen.
///
/// Duplicated here rather than reusing `WindowOccluders`, which is internal to
/// the library. This is a harness, not a second implementation of the library:
/// the layers and filter match, and widening the module's public API to serve a
/// test binary would be the wrong trade.
private func visibleWindowFrames() -> [CGRect] {
    let layers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow))
    ]
    let me = ProcessInfo.processInfo.processIdentifier
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return list.compactMap { entry in
        guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != me,
              let layer = entry[kCGWindowLayer as String] as? Int, layers.contains(layer),
              let b = entry[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
              let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
              w > 0, h > 0
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private extension CGRect {
    /// `CGRect.intersection` can return a null rect for disjoint inputs.
    var area: CGFloat { isEmpty ? 0 : width * height }
}

// MARK: - Child: owns the window and performs the drag

if CommandLine.arguments.contains("--window") {
    // The parent located bare desktop and wrote the start point down.
    guard let raw = try? String(contentsOfFile: startCocoaFile, encoding: .utf8) else {
        print("CHILD no start point at \(startCocoaFile)"); exit(3)
    }
    let parts = raw.split(separator: " ").compactMap { Double($0) }
    guard parts.count == 2 else { print("CHILD bad start point \(raw)"); exit(3) }
    let startCocoa = CGPoint(x: CGFloat(parts[0]), y: CGFloat(parts[1]))
    let endCocoa = CGPoint(x: startCocoa.x + endCocoaOffset.x, y: startCocoa.y + endCocoaOffset.y)

    let w = NSWindow(contentRect: NSRect(origin: startCocoa, size: windowSize),
                     styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
    w.title = "GhostTrailProbe"
    w.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // Let the parent install its event tap before anything moves. The parent
    // signals readiness by writing this file.
    let readyFlag = URL(fileURLWithPath: "/tmp/gt-probe-ready")
    try? FileManager.default.removeItem(at: readyFlag)
    while !FileManager.default.fileExists(atPath: readyFlag.path) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Thread.sleep(forTimeInterval: 0.4)

    if CommandLine.arguments.contains("--level") {
        // Report the level the window server actually gave the dragged window,
        // and the level it gave the overlay, so a "the ribbon is behind
        // everything" bug can be diagnosed without guessing.
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let mine = list.first { ($0[kCGWindowOwnerPID as String] as? Int32)
            == ProcessInfo.processInfo.processIdentifier }
        print("CHILD windowLayer=\(mine?[kCGWindowLayer as String] ?? "MISSING") "
              + "bounds=\(mine?[kCGWindowBounds as String] ?? "MISSING")")
    }

    // Press on the title bar, then move the pointer and the window together.
    // GhostTrail ignores a window that moves by itself (an opening animation, a
    // script, a tiling snap) — the pointer being down on it is what makes the
    // motion worth trailing.
    let pressAt = quartzPoint(fromCocoa: CGPoint(x: w.frame.midX, y: w.frame.maxY - 12))
    post(.leftMouseDown, pressAt)
    Thread.sleep(forTimeInterval: 0.2)

    var frame = w.frame
    let steps = 40
    for step in 1...steps {
        let f = Double(step) / Double(steps)
        frame.origin.x = startCocoa.x + (endCocoa.x - startCocoa.x) * CGFloat(f)
        frame.origin.y = startCocoa.y + (endCocoa.y - startCocoa.y) * CGFloat(f)
        w.setFrame(frame, display: true)
        post(.leftMouseDragged, CGPoint(x: pressAt.x + frame.origin.x - startCocoa.x,
                                        y: pressAt.y + frame.origin.y - startCocoa.y))
        Thread.sleep(forTimeInterval: 1.0 / 60.0)
    }
    print("CHILD dragged to \(w.frame)")

    // Hold the press still for a beat so the parent's screenshots land while a
    // ribbon definitely exists.
    Thread.sleep(forTimeInterval: 0.4)
    post(.leftMouseUp, CGPoint(x: pressAt.x + 480, y: pressAt.y + 120))
    Thread.sleep(forTimeInterval: 0.6)
    exit(0)
}

// MARK: - Parent: the overlay, the run loop, the measurements

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--window", "--level"]
child.standardOutput = FileHandle.standardOutput
child.standardError = FileHandle.standardError

// Pick bare desktop BEFORE starting the overlay, so the search does not see our
// own overlay as a blocker.
// Pick the start point BEFORE the overlay starts, so the search does not see
// our own overlay as a blocker.
//
// A screen with several windows open often has no bare desktop large enough for
// the swept band. That is not a failure — it is the normal case on a busy
// machine, and it is exactly the case where window occlusion decides whether
// the ribbon is visible. So rather than refusing to run, the probe reports the
// clearance it managed and drags anyway: a partially covered band still shows
// the ribbon in the gaps, and where it is hidden under a window is the
// occlusion path being exercised for real.
let spot = findBareDesktopStart()
let start: CGPoint
if let spot {
    start = spot.point
    print("PROBE startPoint=\(start) clearance=\(Int(spot.clearance * 100))% "
          + "band=\(dragBandQuartz(from: start))")
} else {
    let screen = NSScreen.screens.first!.frame
    let band = dragBandQuartz(from: .zero)
    start = CGPoint(x: max(screen.minX + 20, (screen.maxX - band.width) / 2),
                    y: max(screen.minY + 20, (screen.maxY - band.height) / 2))
    print("PROBE startPoint=\(start) clearance=unknown (screen is saturated) "
          + "band=\(dragBandQuartz(from: start))")
}
try "\(start.x) \(start.y)".write(toFile: startCocoaFile, atomically: true, encoding: .utf8)
try child.run()

let trail = GhostTrail()
let started = trail.start()
print("PROBE start=\(started) fallback=\(trail.isUsingGeometryFallback)")

// Tell the child the tap is installed, then spin the main run loop. The child
// cannot begin its drag until this file appears.
Thread.sleep(forTimeInterval: 0.5)
FileManager.default.createFile(atPath: "/tmp/gt-probe-ready", contents: Data())

var peakTrails = 0
var framesWithTrail = 0
var shot = 0
let deadline = Date().addingTimeInterval(6.0)
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
    if trail.activeTrailCount > 0 {
        peakTrails = max(peakTrails, trail.activeTrailCount)
        framesWithTrail += 1
    }
    if shot < 14, trail.activeTrailCount > 0 {
        shot += 1
        _ = screenShot(to: String(format: "/tmp/gt-frame-%02d.png", shot))
    }
}
print("PROBE peakTrails=\(peakTrails) framesWithTrail=\(framesWithTrail) shots=\(shot)")

// Which windows is the window server actually showing, and at what layer?
// The overlay is `overlay(pid=...)`, the dragged window is the child's pid.
let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []
let me = ProcessInfo.processInfo.processIdentifier
for entry in list {
    guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
          let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = bounds["X"] ?? "?"
    let y = bounds["Y"] ?? "?"
    let w = bounds["Width"] ?? "?"
    let h = bounds["Height"] ?? "?"
    print("PROBE win pid=\(pid)\(pid == me ? " (overlay)" : "") "
          + "layer=\(entry[kCGWindowLayer as String] ?? "?") "
          + "bounds=\(x),\(y) \(w)x\(h)")
}
print("PROBE expectedRibbonBand=\(dragBandQuartz(from: start))")

child.waitUntilExit()
trail.stop()
try? FileManager.default.removeItem(atPath: "/tmp/gt-probe-ready")
try? FileManager.default.removeItem(atPath: startCocoaFile)
print("PROBE done")
exit(peakTrails > 0 ? 0 : 1)