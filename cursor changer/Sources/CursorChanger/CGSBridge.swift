import CoreFoundation
import CoreGraphics
import Foundation

/// Bridges the untyped `CGImageRef` entries that
/// `CGSCopyRegisteredCursorImages` / `CoreCursorCopyImages` return inside an
/// `Unmanaged<CFTypeRef>`-ish `UnsafeRawPointer` array.
///
/// The arrays come back with no element type information, so an unchecked
/// `unsafeBitCast` to `CGImage` is a type-confusion trap waiting to happen.
/// `CFGetTypeID` is the only safe way to confirm the element really is an
/// image before reinterpreting it.
func cgImageFromCFValue(_ value: UnsafeRawPointer?) -> CGImage? {
    guard let value else { return nil }
    let cfType = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
    guard CFGetTypeID(cfType) == CGImage.typeID else { return nil }
    return Unmanaged<CGImage>.fromOpaque(value).takeUnretainedValue()
}

enum CGSBridgeError: Error, CustomStringConvertible, LocalizedError {
    case libraryLoadFailed(String)
    case symbolUnavailable(String)

    var description: String {
        switch self {
        case .libraryLoadFailed(let path):
            return "Could not load system frameworks at \(path)"
        case .symbolUnavailable(let name):
            return "Private symbol \(name) is unavailable on this macOS version"
        }
    }

    var errorDescription: String? { description }
}

final class CGSBridge {
    /// Lazily built, cached, and *failable*: nothing on a reachable path can
    /// trap the way `try! CGSBridge()` did when the private symbols are gone.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: CGSBridge?
    nonisolated(unsafe) private static var cachedError: Error?

    static var shared: CGSBridge {
        get throws {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let cached { return cached }
            do {
                let bridge = try CGSBridge()
                cached = bridge
                cachedError = nil
                return bridge
            } catch {
                cachedError = error
                throw error
            }
        }
    }

    /// The reason the last `shared` access failed, if any — lets callers say
    /// *why* the bridge is unavailable instead of just that it is.
    static var lastLoadError: Error? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedError
    }

    let mainConnectionID: () -> Int32
    let registerCursorWithImages: (
        _ cid: Int32,
        _ name: UnsafePointer<CChar>,
        _ setGlobally: Bool,
        _ instantly: Bool,
        _ size: CGSize,
        _ hotspot: CGPoint,
        _ frameCount: Int,
        _ frameDuration: CGFloat,
        _ images: CFArray,
        _ seed: UnsafeMutablePointer<Int32>?
    ) -> CGError
    let unregisterAll: (_ cid: Int32) -> CGError
    let setCoreCursor: (_ cid: Int32, _ cursorID: Int32) -> CGError
    let copyCoreCursorImages: (
        _ cid: Int32,
        _ cursorID: Int32,
        _ images: UnsafeMutablePointer<CFArray?>,
        _ size: UnsafeMutablePointer<CGSize>,
        _ hotspot: UnsafeMutablePointer<CGPoint>,
        _ frameCount: UnsafeMutablePointer<Int>,
        _ frameDuration: UnsafeMutablePointer<CGFloat>
    ) -> CGError
    let currentCursorSeed: () -> Int32
    let setRegisteredCursor: (_ cid: Int32, _ name: UnsafePointer<CChar>, _ seed: UnsafeMutablePointer<Int32>?) -> CGError
    let copyRegisteredCursorImages: (
        _ cid: Int32,
        _ name: UnsafePointer<CChar>,
        _ size: UnsafeMutablePointer<CGSize>?,
        _ hotspot: UnsafeMutablePointer<CGPoint>?,
        _ frameCount: UnsafeMutablePointer<Int>?,
        _ frameDuration: UnsafeMutablePointer<CGFloat>?,
        _ images: UnsafeMutablePointer<CFArray?>?
    ) -> CGError
    let getCursorScale: (_ cid: Int32, _ scale: UnsafeMutablePointer<CGFloat>) -> CGError
    let setCursorScale: (_ cid: Int32, _ scale: CGFloat) -> CGError
    let setDockCursorOverride: (_ cid: Int32, _ flag: Bool) -> Void
    let setSystemDefinedCursor: (_ cid: Int32, _ cursor: Int32) -> CGError
    let getWindowOwner: ((_ cid: Int32, _ windowNumber: UInt32, _ owner: UnsafeMutablePointer<Int32>) -> CGError)?

    private static let libraryPaths = [
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    ]

    private init() throws {
        var handles: [UnsafeMutableRawPointer] = []
        for path in Self.libraryPaths {
            if let handle = dlopen(path, RTLD_LAZY) {
                handles.append(handle)
            }
        }
        guard !handles.isEmpty else {
            throw CGSBridgeError.libraryLoadFailed(Self.libraryPaths.joined(separator: ", "))
        }

        mainConnectionID = try Self.resolve(handles, "CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
        registerCursorWithImages = try Self.resolve(
            handles,
            "CGSRegisterCursorWithImages",
            as: (@convention(c) (
                Int32, UnsafePointer<CChar>, Bool, Bool,
                CGSize, CGPoint, Int, CGFloat, CFArray,
                UnsafeMutablePointer<Int32>?
            ) -> CGError).self
        )
        unregisterAll = try Self.resolve(handles, "CoreCursorUnregisterAll", as: (@convention(c) (Int32) -> CGError).self)
        setCoreCursor = try Self.resolve(handles, "CoreCursorSet", as: (@convention(c) (Int32, Int32) -> CGError).self)
        copyCoreCursorImages = try Self.resolve(
            handles,
            "CoreCursorCopyImages",
            as: (@convention(c) (
                Int32,
                Int32,
                UnsafeMutablePointer<CFArray?>,
                UnsafeMutablePointer<CGSize>,
                UnsafeMutablePointer<CGPoint>,
                UnsafeMutablePointer<Int>,
                UnsafeMutablePointer<CGFloat>
            ) -> CGError).self
        )
        currentCursorSeed = try Self.resolve(handles, "CGSCurrentCursorSeed", as: (@convention(c) () -> Int32).self)
        setRegisteredCursor = try Self.resolve(
            handles,
            "CGSSetRegisteredCursor",
            as: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>?) -> CGError).self
        )
        copyRegisteredCursorImages = try Self.resolve(
            handles,
            "CGSCopyRegisteredCursorImages",
            as: (@convention(c) (
                Int32,
                UnsafePointer<CChar>,
                UnsafeMutablePointer<CGSize>?,
                UnsafeMutablePointer<CGPoint>?,
                UnsafeMutablePointer<Int>?,
                UnsafeMutablePointer<CGFloat>?,
                UnsafeMutablePointer<CFArray?>?
            ) -> CGError).self
        )
        getCursorScale = try Self.resolve(
            handles,
            "CGSGetCursorScale",
            as: (@convention(c) (Int32, UnsafeMutablePointer<CGFloat>) -> CGError).self
        )
        setCursorScale = try Self.resolve(handles, "CGSSetCursorScale", as: (@convention(c) (Int32, CGFloat) -> CGError).self)
        setDockCursorOverride = try Self.resolve(handles, "CGSSetDockCursorOverride", as: (@convention(c) (Int32, Bool) -> Void).self)
        setSystemDefinedCursor = try Self.resolve(handles, "CGSSetSystemDefinedCursor", as: (@convention(c) (Int32, Int32) -> CGError).self)
        getWindowOwner = Self.resolveOptional(
            handles,
            "CGSGetWindowOwner",
            as: (@convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> CGError).self
        )
    }

    private static func resolve<T>(_ handles: [UnsafeMutableRawPointer], _ name: String, as type: T.Type) throws -> T {
        for handle in handles {
            if let ptr = dlsym(handle, name) {
                return unsafeBitCast(ptr, to: type)
            }
        }
        throw CGSBridgeError.symbolUnavailable(name)
    }

    private static func resolveOptional<T>(_ handles: [UnsafeMutableRawPointer], _ name: String, as type: T.Type) -> T? {
        for handle in handles {
            if let ptr = dlsym(handle, name) {
                return unsafeBitCast(ptr, to: type)
            }
        }
        return nil
    }

    static func isAvailable() -> Bool {
        (try? CGSBridge.shared) != nil
    }
}
