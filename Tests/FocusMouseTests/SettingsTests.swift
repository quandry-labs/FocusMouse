import Foundation
import Testing
@testable import FocusMouse

@Suite("Settings")
struct SettingsTests {
    @Test("defaults are correct")
    func defaults() {
        let defaults = UserDefaults(suiteName: "test-settings-defaults")!
        defaults.removePersistentDomain(forName: "test-settings-defaults")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.isEnabled == true)
        #expect(settings.focusDelayMs == 200)
        #expect(settings.raiseWindow == true)
        #expect(settings.raiseDelayMs == 0)
        #expect(settings.excludedBundleIDs.isEmpty)
        #expect(settings.launchAtLogin == true)
        #expect(settings.showInDock == false)
    }

    @Test("persists changes to UserDefaults")
    func persistence() {
        let defaults = UserDefaults(suiteName: "test-settings-persist")!
        defaults.removePersistentDomain(forName: "test-settings-persist")
        let settings = AppSettings(defaults: defaults)

        settings.focusDelayMs = 500
        settings.raiseWindow = false
        settings.excludedBundleIDs = ["com.apple.finder"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.focusDelayMs == 500)
        #expect(reloaded.raiseWindow == false)
        #expect(reloaded.excludedBundleIDs == ["com.apple.finder"])
    }

    @Test("focusDelay clamped to 0-1000")
    func focusDelayClamping() {
        let defaults = UserDefaults(suiteName: "test-settings-clamp")!
        defaults.removePersistentDomain(forName: "test-settings-clamp")
        let settings = AppSettings(defaults: defaults)

        settings.focusDelayMs = -50
        #expect(settings.focusDelayMs == 0)

        settings.focusDelayMs = 2000
        #expect(settings.focusDelayMs == 1000)
    }

    @Test("raiseDelay clamped to 0-500")
    func raiseDelayClamping() {
        let defaults = UserDefaults(suiteName: "test-settings-raise-clamp")!
        defaults.removePersistentDomain(forName: "test-settings-raise-clamp")
        let settings = AppSettings(defaults: defaults)

        settings.raiseDelayMs = -10
        #expect(settings.raiseDelayMs == 0)

        settings.raiseDelayMs = 999
        #expect(settings.raiseDelayMs == 500)
    }
}
