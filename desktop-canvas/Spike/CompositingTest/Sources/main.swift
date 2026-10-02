import AppKit
import AVFoundation
import QuartzCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Pass the video to play: `swift run CompositingTest /path/to/video.mp4`
let videoPath = CommandLine.arguments.dropFirst().first ?? ""
guard !videoPath.isEmpty else {
    print("usage: swift run CompositingTest /path/to/video.mp4")
    exit(2)
}

print("=== Desktop Video Background Test ===\n")
print("Level: kCGDesktopIconWindowLevel = \(CGWindowLevelForKey(.desktopIconWindow))")
print("Video: \(videoPath)")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

let screen = NSScreen.main!
let window = NSWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
window.isOpaque = false
window.hasShadow = false
window.ignoresMouseEvents = true
window.backgroundColor = .clear
window.collectionBehavior = [
    .canJoinAllSpaces,
    .fullScreenAuxiliary,
    .stationary,
    .transient,
    .ignoresCycle
]
window.contentView?.wantsLayer = true
window.contentView?.clipsToBounds = true

let playerItem = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
let player = AVPlayer(playerItem: playerItem)
player.actionAtItemEnd = .none
player.volume = 0.3
player.isMuted = false

let playerLayer = AVPlayerLayer()
playerLayer.player = player
playerLayer.frame = window.contentView!.bounds
playerLayer.videoGravity = .resizeAspectFill
playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
window.contentView?.layer?.addSublayer(playerLayer)

NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: playerItem,
    queue: .main
) { _ in
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        player.play()
    }
}

window.order(.below, relativeTo: 0)
player.play()

print("Video playing as desktop background.")
print("  - Behind icons?   Should be YES")
print("  - Icons clickable? Should be YES")
print("  - Mission Control? Should survive")
print("  - Spaces?         Should follow")
print("  - 60fps smooth?   Observe")
print("\nPress Cmd+Q or close terminal to quit.\n")

app.run()