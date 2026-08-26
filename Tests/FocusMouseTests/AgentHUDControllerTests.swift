import AppKit
import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("Agent HUD controller", .serialized)
struct AgentHUDControllerTests {
    @Test("Agent HUD panels are click-through and non-activating")
    func panelIsClickThrough() {
        let suiteName = "test-agent-hud-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let systemHUD = SystemHUDController(settings: settings)
        let controller = AgentHUDController(settings: settings, systemHUD: systemHUD)
        let panel = controller.makePanel()

        #expect(panel.ignoresMouseEvents)
        #expect(!panel.acceptsMouseMovedEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
}
