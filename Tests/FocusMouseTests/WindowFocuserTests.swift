import CoreGraphics
import Testing
@testable import FocusMouse

@MainActor
@Suite("WindowFocuser")
struct WindowFocuserTests {
    @Test("reports accessibility trust status")
    func accessibilityTrustStatus() {
        let focuser = WindowFocuser()
        _ = focuser.isAccessibilityTrusted
        focuser.stopPollingPermission()
    }

    @Test("mock records exact target window and point")
    func mockFocuserRecordsCalls() {
        let mock = MockWindowFocuser()
        let point = CGPoint(x: 12, y: 24)
        let window = WindowInfo(
            windowID: 7,
            ownerPID: 123,
            ownerBundleID: "com.example.target",
            ownerName: "Target",
            bounds: .zero,
            layer: 0,
            isOnScreen: true
        )

        let result = mock.focusWindow(window, at: point, raiseWindow: true)

        #expect(result)
        #expect(mock.focusCalls == [.init(window: window, point: point, raiseWindow: true)])
    }
}
