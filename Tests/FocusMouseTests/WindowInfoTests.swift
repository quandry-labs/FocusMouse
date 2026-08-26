import Testing
@testable import FocusMouse

@Suite("Window lookup")
struct WindowInfoTests {
    @Test("Stage Manager interaction surfaces block pointer focus")
    func stageManagerSurfaceBlocksFocus() {
        #expect(WindowInfo.blocksPointerFocus(bundleIdentifier: "com.apple.WindowManager"))
    }

    @Test("regular app windows remain focusable")
    func regularAppDoesNotBlockFocus() {
        #expect(!WindowInfo.blocksPointerFocus(bundleIdentifier: "com.apple.mail"))
        #expect(!WindowInfo.blocksPointerFocus(bundleIdentifier: nil))
    }
}
