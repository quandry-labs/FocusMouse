import Foundation
import Testing
@testable import FocusMouse

@Suite("WindowFocuser")
struct WindowFocuserTests {
    @Test("reports accessibility trust status")
    func accessibilityTrustStatus() {
        let focuser = WindowFocuser()
        let _ = focuser.isAccessibilityTrusted
    }

    @Test("mock focuser records calls")
    func mockFocuserRecordsCalls() {
        let mock = MockWindowFocuser()
        mock.focusResult = true

        let result = mock.focusWindow(pid: 123, raiseWindow: true)

        #expect(result == true)
        #expect(mock.focusCalls.count == 1)
        #expect(mock.focusCalls[0].pid == 123)
        #expect(mock.focusCalls[0].raiseWindow == true)
    }
}

