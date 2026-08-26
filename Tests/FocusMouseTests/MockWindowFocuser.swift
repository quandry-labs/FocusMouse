import CoreGraphics
import Foundation
@testable import FocusMouse

@MainActor
final class MockWindowFocuser: WindowFocusing {
    struct FocusCall: Equatable {
        let window: WindowInfo
        let point: CGPoint
        let raiseWindow: Bool
    }

    var isAccessibilityTrusted = true
    var focusResult = true
    private(set) var focusCalls: [FocusCall] = []

    func focusWindow(_ window: WindowInfo, at point: CGPoint, raiseWindow: Bool) -> Bool {
        focusCalls.append(FocusCall(window: window, point: point, raiseWindow: raiseWindow))
        return focusResult
    }

    func requestAccessibilityPermission() {}
}
