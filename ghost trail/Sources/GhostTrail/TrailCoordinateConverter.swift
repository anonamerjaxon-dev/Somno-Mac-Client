import AppKit
import CoreGraphics

/// Converts window frames reported by `CGWindowListCopyWindowInfo` into the local,
/// bottom-left-origin coordinate space of the trail overlay's content view.
///
/// Three coordinate spaces are involved:
///
/// 1. **Quartz global** — what `CGWindowListCopyWindowInfo` reports. Origin is the
///    top-left of the main display, `+y` points *down*.
/// 2. **Cocoa global** — `NSScreen.frame` / `NSWindow.frame`. Origin is the
///    bottom-left of the main display, `+y` points *up*. Conversion is a single
///    vertical flip measured against the **main** display's height, which is
///    correct for secondary displays above, below, left or right of it.
/// 3. **View local** — what `Canvas { context, size in ... }` draws in. The
///    overlay window is sized to the union of all screens, so local = cocoa
///    global minus the overlay frame's origin.
///
/// Steps 1→2 must use the main display's height (not the overlay's), otherwise
/// trails drawn on any display other than the main one land mirrored or clipped.
struct TrailCoordinateConverter: Equatable {
    /// Height of the main display in Cocoa points — the axis of the y-flip.
    let mainDisplayHeight: CGFloat
    /// Origin of the main display in Cocoa points.
    let mainDisplayOrigin: CGPoint
    /// Origin of the overlay window in Cocoa points.
    let overlayOrigin: CGPoint

    init(mainDisplayFrame: NSRect, overlayFrame: NSRect) {
        self.mainDisplayHeight = mainDisplayFrame.height
        self.mainDisplayOrigin = mainDisplayFrame.origin
        self.overlayOrigin = overlayFrame.origin
    }

    /// Fallback used when no display is attached (headless CI, all screens asleep).
    static let identity = TrailCoordinateConverter(
        mainDisplayFrame: NSRect(x: 0, y: 0, width: 0, height: 0),
        overlayFrame: .zero
    )

    /// Quartz-global rect → overlay-view-local rect.
    func viewRect(fromQuartz rect: CGRect) -> CGRect {
        let cocoaX = rect.origin.x + mainDisplayOrigin.x
        let cocoaY = mainDisplayOrigin.y + mainDisplayHeight - (rect.origin.y + rect.height)
        return CGRect(
            x: cocoaX - overlayOrigin.x,
            y: cocoaY - overlayOrigin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Quartz-global point → overlay-view-local point (no size to flip).
    func viewPoint(fromQuartz point: CGPoint) -> CGPoint {
        let cocoaY = mainDisplayOrigin.y + mainDisplayHeight - point.y
        return CGPoint(x: point.x + mainDisplayOrigin.x - overlayOrigin.x,
                       y: cocoaY - overlayOrigin.y)
    }
}