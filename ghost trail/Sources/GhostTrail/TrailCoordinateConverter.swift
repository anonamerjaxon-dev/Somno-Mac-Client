import AppKit
import CoreGraphics

/// Converts window frames reported by `CGWindowListCopyWindowInfo` into the local,
/// bottom-left-origin coordinate space of the trail overlay's content view.
///
/// Three coordinate spaces are involved: Quartz global (top-left of the main
/// display, `+y` down), Cocoa global (bottom-left of the main display, `+y` up),
/// and the overlay's view-local space. The 1→2 flip is a single vertical
/// reflection measured against the **main** display's height — using the
/// overlay's height instead would mirror trails on any secondary display.
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

    /// Fallback used when no display is attached (headless CI, all screens
    /// asleep).
    ///
    /// With no reference display there is no meaningful y-flip to perform: the
    /// origin's height is zero, so the flip is the identity. Returning `.zero`
    /// rects instead would be a lie about geometry the caller cannot check, and
    /// this is the fallback precisely for the case where nothing is visible.
    static let identity = TrailCoordinateConverter(
        mainDisplayFrame: NSRect(x: 0, y: 0, width: 0, height: 0),
        overlayFrame: .zero
    )

    /// True when this converter has a real reference display to flip about.
    var isUsable: Bool { mainDisplayHeight > 0 }

    /// Quartz-global rect → overlay-view-local rect.
    func viewRect(fromQuartz rect: CGRect) -> CGRect {
        // No reference display means no flip: pass the rect through translated by
        // the overlay origin only. See `identity`.
        guard isUsable else {
            return CGRect(
                x: rect.minX - overlayOrigin.x,
                y: rect.minY - overlayOrigin.y,
                width: rect.width,
                height: rect.height
            )
        }

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
        guard isUsable else {
            return CGPoint(x: point.x - overlayOrigin.x, y: point.y - overlayOrigin.y)
        }
        let cocoaY = mainDisplayOrigin.y + mainDisplayHeight - point.y
        return CGPoint(x: point.x + mainDisplayOrigin.x - overlayOrigin.x,
                       y: cocoaY - overlayOrigin.y)
    }
}