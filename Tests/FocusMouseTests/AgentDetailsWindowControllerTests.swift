import AppKit
import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("Agent details window", .serialized)
struct AgentDetailsWindowControllerTests {
    @Test("Details window is interactive, resizable, and distinct from the HUD")
    func detailsWindowIsInteractive() {
        let suiteName = "test-agent-details-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let systemHUD = SystemHUDController(settings: settings)
        let agentHUD = AgentHUDController(settings: settings, systemHUD: systemHUD)
        let controller = AgentDetailsWindowController(agentHUD: agentHUD, settings: settings)
        let window = controller.makeWindow()

        #expect(!window.ignoresMouseEvents)
        #expect(window.canBecomeKey)
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.minSize.width >= 760)
        #expect(window.contentViewController != nil)
    }
}
