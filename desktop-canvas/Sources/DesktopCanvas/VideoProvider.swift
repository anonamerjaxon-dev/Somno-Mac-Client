import AppKit
import AVFoundation
import QuartzCore

final class VideoProvider: CanvasProvider {
    var canvas: CanvasModel

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var placeholderView: NSView?
    private var loopObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var ownerView: NSView?
    private var playbackDeferred = true
    private var occlusionObserverInstalledFor: NSWindow?

    init(canvas: CanvasModel) {
        self.canvas = canvas
    }

    func attach(to superview: NSView, frame _: NSRect) {
        guard let config = canvas.videoConfig else { return }
        ownerView = superview

        let fileExists = FileManager.default.fileExists(atPath: config.videoURL.path)

        let contentSize = CGSize(
            width: max(canvas.frame.size.width, 1),
            height: max(canvas.frame.size.height, 1)
        )

        if !fileExists || config.videoURL.path.isEmpty {
            showPlaceholder(in: superview, size: contentSize)
            return
        }

        let asset = AVAsset(url: config.videoURL)
        let playerItem = AVPlayerItem(asset: asset)

        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        player.volume = Float(config.volume)
        self.player = player

        let layer = AVPlayerLayer()
        layer.player = player
        layer.frame = CGRect(origin: .zero, size: contentSize)
        layer.videoGravity = .resizeAspectFill
        superview.layer?.addSublayer(layer)
        self.playerLayer = layer

        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            DispatchQueue.main.async {
                self.showPlaceholder(in: superview, size: contentSize,
                                     message: "Playback failed: \(item.error?.localizedDescription ?? "unknown")")
            }
        }

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, let player = self.player, self.playerLayer?.superlayer != nil else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                if finished { player.play() }
            }
        }

        // `attach` runs before the renderer is added to the window's content view, so
        // there is no window to observe yet. `update()` re-checks until one exists.
        installOcclusionObserverIfPossible()

        playbackDeferred = true
    }

    /// Installs the occlusion observer once the provider's view is in a window.
    ///
    /// Called from `update()` as well as `attach`, because at `attach` time the
    /// renderer has not been added to a window yet and `superview.window` is nil.
    /// Idempotent: it does nothing once installed for the current window.
    func installOcclusionObserverIfPossible() {
        guard occlusionObserver == nil, let window = ownerView?.window else { return }

        occlusionObserverInstalledFor = window
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyOcclusionState()
        }

        // The observer only fires on a *change*, so honour the state we start in.
        applyOcclusionState()
    }

    private func applyOcclusionState() {
        guard let window = ownerView?.window, occlusionObserver != nil else { return }
        if window.occlusionState.contains(.visible) {
            player?.play()
        } else {
            player?.pause()
        }
    }

    private func showPlaceholder(in superview: NSView, size: CGSize, message: String = "Missing Video") {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.darkGray.cgColor

        let label = NSTextField(labelWithString: "\u{26A0} \(message)")
        label.textColor = NSColor.lightGray
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14)
        label.frame = container.bounds
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)

        superview.addSubview(container)
        self.placeholderView = container
    }

    func detach() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        occlusionObserverInstalledFor = nil
        statusObserver?.invalidate()
        statusObserver = nil
        ownerView = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil
    }

    func update() {
        let newSize = canvas.frame.size
        if playerLayer?.frame.size != newSize {
            playerLayer?.frame = NSRect(origin: .zero, size: newSize)
        }
        if let newVolume = canvas.videoConfig?.volume,
           player?.volume != Float(newVolume) {
            player?.volume = Float(newVolume)
        }
        installOcclusionObserverIfPossible()
        if playbackDeferred, canvas.frame.size.width > 0, canvas.frame.size.height > 0 {
            playbackDeferred = false
            player?.play()
        }
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }
}