import Cocoa
import CoreGraphics

struct WindowInfo: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String?
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool

    static func windowAtPoint(_ point: CGPoint, excludingPID: pid_t) -> WindowInfo? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for entry in windowList {
            guard
                let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let x = boundsDict["X"],
                let y = boundsDict["Y"],
                let w = boundsDict["Width"],
                let h = boundsDict["Height"],
                let layer = entry[kCGWindowLayer as String] as? Int
            else { continue }

            if pid == excludingPID { continue }
            if layer != 0 { continue }

            let bounds = CGRect(x: x, y: y, width: w, height: h)
            guard bounds.width > 1, bounds.height > 1 else { continue }
            guard bounds.contains(point) else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? CGFloat) ?? 1
            guard alpha > 0.01 else { continue }

            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true
            guard isOnScreen else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }

            // Stage Manager places its own interaction windows in front of the
            // app thumbnails. Falling through those accessory windows makes a
            // thumbnail look like a regular app window and `activate()` then
            // has the same visible result as clicking the thumbnail.
            if blocksPointerFocus(bundleIdentifier: app.bundleIdentifier) {
                return nil
            }

            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier
            else {
                continue
            }

            let ownerName = entry[kCGWindowOwnerName as String] as? String

            return WindowInfo(
                windowID: windowID,
                ownerPID: pid,
                ownerBundleID: bundleID,
                ownerName: ownerName,
                bounds: bounds,
                layer: layer,
                isOnScreen: isOnScreen
            )
        }
        return nil
    }

    static func blocksPointerFocus(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.WindowManager"
    }
}
