import CoreGraphics

/// Translates canvas frames between the space `CanvasLayout` stores and the
/// places they are drawn: one borderless `CanvasWindow` per `NSScreen`, and the
/// editor's scaled preview.
///
/// ## One convention, everywhere: bottom-left origin, y grows upward
///
/// There is exactly one coordinate convention in this module, and both
/// destinations share it with the stored layout:
///
/// * `CanvasLayout` stores frames in Cocoa global space (`NSScreen.frame`).
/// * `CanvasWindow` is positioned with `NSWindow.setFrame`, which is that same
///   bottom-left, y-up space, so `localFrame` only translates.
/// * The editor preview's `LayoutNSView` does **not** override `isFlipped`, so
///   it is also y-up. `previewRect` therefore only scales and translates — it
///   must **not** flip y.
///
/// This matters: a flip in only one of the two mappings makes the same canvas
/// appear near the top of the editor while rendering near the bottom of the
/// screen (the dock side). Any future view that draws the layout must either
/// stay unflipped, or the mapping that feeds it must flip — never one without
/// the other. `OverlapMathTests` pins this agreement.
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
    /// Pure scale-and-translate, no y flip: the preview view is unflipped (see
    /// the type comment), so it shares the stored layout's orientation.
    ///
    /// - Parameters:
    ///   - rect: canvas rect in the space `CanvasLayout` stores.
    ///   - scale: preview scale factor.
    ///   - offset: preview offset, already in view coordinates. The caller folds
    ///     the union's origin into it, so the union is not needed here.
    public static func previewRect(
        for rect: CGRect,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        CGRect(
            x: rect.minX * scale + offset.x,
            y: rect.minY * scale + offset.y,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// Inverse of `previewRect(for:scale:offset:)` for a single point.
    public static func canvasPoint(
        fromViewPoint viewPoint: CGPoint,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (viewPoint.x - offset.x) / scale,
            y: (viewPoint.y - offset.y) / scale
        )
    }
}
