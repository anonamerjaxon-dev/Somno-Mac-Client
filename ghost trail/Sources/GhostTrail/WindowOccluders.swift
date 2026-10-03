import AppKit
import CoreGraphics

/// The live frames of the windows that must *appear* to be on top of the trail.
///
/// The trail overlay cannot use z-order to sit behind application windows:
/// macOS composites nothing below `kCGNormalWindowLevel` (measured — a window at
/// `kCGDesktopIconWindowLevel`, at `normal - 1`, and at every level between
/// produced the same 475 pixels as an off-screen baseline, while `normal`
/// produced 320,475). So the overlay is drawn above everything, and the illusion
/// of depth is produced by erasing the part of the ribbon that the dragged
/// window covers.
///
/// That means the renderer needs to know every on-screen window's frame, not
/// just the trailed ones. `CGWindowListCopyWindowInfo` is already being polled
/// once per tick for the tracker; this is that same data, filtered to the
/// windows a user can actually see.
enum WindowOccluders {
    /// Layers that hold windows the trail should pass beneath: normal windows,
    /// and the floating/panel layers that sit just above them. Everything the
    /// window server draws above `kCGFloatingWindowLevel` (menus, status items,
    /// Control Centre, screen savers) is deliberately excluded — erasing around a
    /// menu bar would punch holes in the ribbon for no visual gain.
    private static let occludingLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow))
    ]

    /// Frames of every visible, non-overlay window owned by another process.
    ///
    /// - Parameters:
    ///   - excludingPID: never occlude with our own windows; the overlay is one
    ///     and erasing it would erase the entire trail.
    static func visibleFrames(excludingPID pid: Int32) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var rects: [CGRect] = []
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32, ownerPID != pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, occludingLayers.contains(layer) else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0, height > 0
            else { continue }
            rects.append(CGRect(x: x, y: y, width: width, height: height))
        }
        return rects
    }

    /// The rectangles that should be punched out of a ribbon occupying `frame`.
    ///
    /// Returns only the intersections, so the renderer never has to clip-test a
    /// path against windows that miss it entirely. Windows that fully contain the
    /// ribbon collapse to a single covering rect.
    ///
    /// - Parameter slop: expands each hole by this many points.
    ///
    ///   The head outline is a *stroke* centred on the window's own rectangle, so
    ///   half of its width sits outside the window's frame. Erasing exactly to
    ///   the frame leaves that outer half behind: measured 250 pixels forming a
    ///   bright outline drawn straight across the face of the occluding window —
    ///   precisely the artefact this whole mechanism exists to avoid. Ink outside
    ///   a window belongs to nobody, so the hole is widened past it. Cost is nil,
    ///   because a hole is only ever an occluder the ribbon would otherwise have
    ///   run under, and the occluding window hides the slop anyway.
    static func occludingRects(for frame: CGRect, among windows: [CGRect], slop: CGFloat = 0) -> [CGRect] {
        guard slop > 0 else {
            return windows.compactMap { $0.intersection(frame) }.filter { !$0.isEmpty }
        }
        return windows
            .map { $0.insetBy(dx: -slop, dy: -slop) }
            .compactMap { $0.intersection(frame) }
            .filter { !$0.isEmpty }
    }
}