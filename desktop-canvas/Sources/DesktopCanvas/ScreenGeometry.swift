import CoreGraphics

/// Translates canvas frames between the space `CanvasLayout` stores and the
/// places they are drawn: one borderless `CanvasWindow` per `NSScreen`, and the
/// editor's scaled preview.
///
/// Both destinations are *upside down* relative to the stored layout, and for
/// the same reason: `CanvasWindow` is positioned with `NSWindow.setFrame`, whose
/// rectangle is in the bottom-left, y-up Cocoa global space that `NSScreen.frame`
/// also uses. The stored layout follows the same convention, so a canvas frame is
/// used verbatim there. The editor preview, however, draws like a document — top
/// edge first — so its mapping flips y for the whole arrangement. That is why
/// `previewRect` flips and `localFrame` does not: without the preview flip a
/// canvas would appear near the top of the editor while rendering near the bottom
/// of the screen (the dock side).
public enum ScreenGeometry {

    // MARK: - Per-screen windows

    /// Canvas rect → the window-local rect of the window covering `screen`.
    ///
    /// Only the origin moves: `canvasWindow` places the window at `screen.frame`,
    /// so subtracting the screen origin is exactly the translation from Cocoa
    /// global coordinates into that window's content view. A canvas straddling
    /// two displays is therefore clipped by its window, which is the intended
    /// behaviour — each screen shows its own slice.
    public static func localFrame(for rect: CGRect, in screen: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screen.minX,
            y: rect.minY - screen.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Inverse of `localFrame(for:in:)`: window-local rect → canvas rect.
    public static func globalFrame(for rect: CGRect, in screen: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + screen.minX,
            y: rect.minY + screen.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Point counterpart of `localFrame(for:in:)`.
    public static func localPoint(for point: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: point.y - screen.minY)
    }

    /// Inverse of `localPoint(for:in:)`.
    public static func globalPoint(fromLocal point: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: point.x + screen.minX, y: point.y + screen.minY)
    }

    // MARK: - Per-screen visibility

    /// Canvases with any visible area on `screen`, in the caller's order.
    ///
    /// A canvas straddling two displays is reported by both screens: each
    /// window shows its own slice of it.
    public static func canvasesVisible(on screen: CGRect, in canvases: [CanvasModel]) -> [CanvasModel] {
        canvases.filter { $0.frame.intersects(screen) }
    }

    // MARK: - Editor preview

    /// Canvas rect → the editor preview's rect.
    ///
    /// - Parameters:
    ///   - rect: canvas rect in the space `CanvasLayout` stores.
    ///   - unionFrame: the Cocoa union of every screen the preview covers.
    ///   - scale: preview scale factor.
    ///   - offset: preview offset, already in view coordinates.
    public static func previewRect(
        for rect: CGRect,
        unionFrame: CGRect,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        CGRect(
            x: (rect.minX - unionFrame.minX) * scale + offset.x,
            y: (unionFrame.maxY - rect.maxY) * scale + offset.y,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Inverse of `previewRect(for:unionFrame:scale:offset:)` for a single point.
    public static func canvasPoint(
        fromViewPoint viewPoint: CGPoint,
        unionFrame: CGRect,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (viewPoint.x - offset.x) / scale + unionFrame.minX,
            y: unionFrame.maxY - (viewPoint.y - offset.y) / scale
        )
    }
}
