import Foundation
@testable import FocusMouse

final class MockWindowFocuser: WindowFocusing {
    var isAccessibilityTrusted: Bool = true
    var focusResult: Bool = true
    var focusCalls: [(pid: pid_t, raiseWindow: Bool)] = []

    func focusWindow(pid: pid_t, raiseWindow: Bool) -> Bool {
        focusCalls.append((pid: pid, raiseWindow: raiseWindow))
        return focusResult
    }

    func requestAccessibilityPermission() {}
}
