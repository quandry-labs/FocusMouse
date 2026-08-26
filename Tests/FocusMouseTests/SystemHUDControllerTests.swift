import AppKit
import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("System HUD controller", .serialized)
struct SystemHUDControllerTests {
    @Test("HUD panels cannot receive mouse or keyboard focus")
    func panelIsClickThrough() {
        let suiteName = "test-hud-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = SystemHUDController(settings: AppSettings(defaults: defaults))
        let panel = controller.makePanel()

        #expect(panel.ignoresMouseEvents)
        #expect(!panel.acceptsMouseMovedEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
}
