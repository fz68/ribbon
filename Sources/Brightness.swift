import Foundation
import CoreGraphics

/// Brightness control through the private DisplayServices framework.
/// No Accessibility permission, no AppleScript and no key injection are used.
enum Brightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let api: (get: GetBrightness, set: SetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(getSymbol, to: GetBrightness.self),
                unsafeBitCast(setSymbol, to: SetBrightness.self))
    }()

    /// The built-in display, falling back to the main display.
    private static func displayID() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(16, &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return CGMainDisplayID()
    }

    /// Applies `delta` to the current brightness (clamped to 0...1) and returns the new value.
    /// Returns nil when DisplayServices or its symbols are unavailable, or when a call fails.
    static func adjust(by delta: Float) -> Float? {
        guard let api else { return nil }
        let display = displayID()
        var current: Float = 0
        guard api.get(display, &current) == 0 else { return nil }
        let target = min(max(current + delta, 0), 1)
        guard api.set(display, target) == 0 else { return nil }
        return target
    }
}
