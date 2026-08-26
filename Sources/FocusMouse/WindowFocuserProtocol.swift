import CoreGraphics
import Foundation

@MainActor
protocol WindowFocusing {
    var isAccessibilityTrusted: Bool { get }
    func focusWindow(_ window: WindowInfo, at point: CGPoint, raiseWindow: Bool) -> Bool
    func requestAccessibilityPermission()
}
