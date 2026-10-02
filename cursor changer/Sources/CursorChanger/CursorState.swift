import AppKit

public enum CursorState: String, CaseIterable, Codable {
    case arrow
    case ibeam
    case pointingHand
    case crosshair
    case openHand
    case closedHand
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeLeftRight
    case resizeUpDown
    case move
    case operationNotAllowed
    case dragCopy
    case dragLink
    case contextMenu
    case busyAndArrow

    public static let fileExtensions = ["png", "svg", "jpg", "jpeg", "tiff"]

    var cgsNames: [String] {
        switch self {
        case .arrow:
            return ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS", "com.apple.cursor.0"]
        case .ibeam:
            return ["com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamS", "com.apple.coregraphics.IBeamXOR", "com.apple.cursor.1"]
        case .pointingHand:
            return ["com.apple.coregraphics.PointingHand", "com.apple.cursor.13"]
        case .crosshair:
            return ["com.apple.coregraphics.Crosshair"]
        case .openHand:
            return ["com.apple.coregraphics.OpenHand", "com.apple.cursor.12"]
        case .closedHand:
            return ["com.apple.coregraphics.ClosedHand", "com.apple.cursor.11"]
        case .resizeLeft:
            return ["com.apple.coregraphics.ResizeLeft", "com.apple.cursor.17"]
        case .resizeRight:
            return ["com.apple.coregraphics.ResizeRight", "com.apple.cursor.18"]
        case .resizeUp:
            return ["com.apple.coregraphics.ResizeUp", "com.apple.cursor.21"]
        case .resizeDown:
            return ["com.apple.coregraphics.ResizeDown", "com.apple.cursor.22"]
        case .resizeLeftRight:
            return ["com.apple.coregraphics.ResizeLeftRight", "com.apple.cursor.19"]
        case .resizeUpDown:
            return ["com.apple.coregraphics.ResizeUpDown", "com.apple.cursor.23"]
        case .move:
            return ["com.apple.coregraphics.Move", "com.apple.cursor.39"]
        case .operationNotAllowed:
            return ["com.apple.coregraphics.NotAllowed", "com.apple.cursor.3"]
        case .dragCopy:
            return ["com.apple.coregraphics.Copy", "com.apple.cursor.5"]
        case .dragLink:
            return ["com.apple.coregraphics.Alias", "com.apple.cursor.2"]
        case .contextMenu:
            return ["com.apple.coregraphics.ArrowCtx", "com.apple.cursor.24"]
        case .busyAndArrow:
            return ["com.apple.coregraphics.Wait", "com.apple.cursor.4"]
        }
    }

    var systemCursor: NSCursor? {
        switch self {
        case .arrow: return NSCursor.arrow
        case .ibeam: return NSCursor.iBeam
        case .pointingHand: return NSCursor.pointingHand
        case .crosshair: return NSCursor.crosshair
        case .openHand: return NSCursor.openHand
        case .closedHand: return NSCursor.closedHand
        case .resizeLeft: return NSCursor.resizeLeft
        case .resizeRight: return NSCursor.resizeRight
        case .resizeUp: return NSCursor.resizeUp
        case .resizeDown: return NSCursor.resizeDown
        case .resizeLeftRight: return NSCursor.resizeLeftRight
        case .resizeUpDown: return NSCursor.resizeUpDown
        case .move: return nil
        case .operationNotAllowed: return NSCursor.operationNotAllowed
        case .dragCopy: return NSCursor.dragCopy
        case .dragLink: return NSCursor.dragLink
        case .contextMenu: return NSCursor.contextualMenu
        case .busyAndArrow: return nil
        }
    }
}
