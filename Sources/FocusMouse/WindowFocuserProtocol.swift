import Foundation

protocol WindowFocusing {
    var isAccessibilityTrusted: Bool { get }
    func focusWindow(pid: pid_t, raiseWindow: Bool) -> Bool
    func requestAccessibilityPermission()
}
