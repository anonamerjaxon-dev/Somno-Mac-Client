import AppKit
import AVFoundation
import QuartzCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)

class LoopTestDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var player: AVPlayer!
    var playerLayer: AVPlayerLayer!
    var loopCount = 0
    let maxLoops = 20
    var gapFramesDetected = 0
    var gapTimes: [Double] = []
    var videoDuration: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== S0.5 AVPlayer Seamless Loop Test ===\n")
        print("This test loops a video 20 times and measures gaps at loop boundaries.")
        print("You must provide a short MP4 file (3-10 seconds).\n")

        // Pass the video to loop: `swift run LoopTest /path/to/video.mp4`
        let testVideoPath = CommandLine.arguments.dropFirst().first ?? ""

        guard !testVideoPath.isEmpty,
              FileManager.default.fileExists(atPath: testVideoPath) else {
            print("ERROR: No test video found at \(testVideoPath.isEmpty ? "<no path given>" : testVideoPath)")
            print("Usage: swift run LoopTest /path/to/short_video.mp4  (3-10 seconds)")
            print("Press Cmd+Q to quit.")
            createPlaceholderWindow()
            return
        }

        print("Using video: \(testVideoPath)\n")
        setupLoopTest(videoPath: testVideoPath)
    }

    func createPlaceholderWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "S0.5: Loop Test — No Video Found"
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func setupLoopTest(videoPath: String) {
        let windowFrame = NSRect(x: 200, y: 200, width: 480, height: 320)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "S0.5: AVPlayer Seamless Loop Test"

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.clipsToBounds = true

        let url = URL(fileURLWithPath: videoPath)
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        player.volume = 0.0

        playerLayer = AVPlayerLayer()
        playerLayer.player = player
        playerLayer.frame = contentView.bounds
        playerLayer.videoGravity = .resizeAspect
        contentView.layer?.addSublayer(playerLayer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        let frameRate = asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30

        print("Video frame rate: \(frameRate) fps")
        print("Looping \(maxLoops) times...\n")

        player.play()
        loopCount = 1
        print("Loop 1: playing...")

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc func playerDidFinishPlaying(_ notification: Notification) {
        let endTime = player.currentTime()

        if videoDuration == 0 {
            videoDuration = endTime.seconds
            print("Video duration: \(String(format: "%.2f", videoDuration))s\n")
        }

        let loopEnd = Date()

        loopCount += 1

        if loopCount <= maxLoops {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self = self, finished else { return }
                let gap = Date().timeIntervalSince(loopEnd)
                if gap > 0.05 {
                    self.gapFramesDetected += 1
                    self.gapTimes.append(gap)
                    let frames = Int(gap * 60)
                    print("Loop \(self.loopCount - 1) \u{2192} \(self.loopCount): GAP — \(String(format: "%.3f", gap))s (~\(frames) frames)")
                } else {
                    print("Loop \(self.loopCount - 1) \u{2192} \(self.loopCount): seamless (\(String(format: "%.3f", gap))s)")
                }
                self.player.play()
            }
        } else {
            print("\n=== Loop Test Complete ===")
            print("Total loops: \(loopCount - 1)")
            print("Gap detections: \(gapFramesDetected)")
            if !gapTimes.isEmpty {
                let avgGap = gapTimes.reduce(0, +) / Double(gapTimes.count)
                print("Average gap: \(String(format: "%.3f", avgGap))s (~\(Int(avgGap * 30)) frames at 30fps)")
                print("Max gap: \(String(format: "%.3f", gapTimes.max()!))s")
            }
            print("\nVerdict:")
            if gapFramesDetected == 0 {
                print("  PASS — Zero visible gaps. actionAtItemEnd + seek(to: .zero) works.")
            } else {
                let avgGap = gapTimes.reduce(0, +) / Double(gapTimes.count)
                if avgGap <= 0.034 {
                    print("  ACCEPTABLE — gap ≤ 1 frame. Two-player crossfade NOT needed.")
                } else {
                    print("  FAIL — Visible gaps. Two-player crossfade RECOMMENDED.")
                    print("  Running two-player crossfade prototype...")
                    runTwoPlayerCrossfade()
                }
            }
        }
    }

    func runTwoPlayerCrossfade() {
        print("\n=== Two-Player Crossfade Prototype ===")
        print("This demonstrates the approach for seamless looping if gaps exist.")
        print("Strategy: Player A plays. 0.5s before end, Player B starts at opacity 0.")
        print("Crossfade A→B over 0.3s. Swap roles. Repeat.")
        print("(Full implementation would require a separate prototype.)")
        print("\nCheck REPORT.md for findings on whether two-player crossfade is needed.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let delegate = LoopTestDelegate()
app.delegate = delegate
app.run()