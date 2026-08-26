import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test("defaults are correct")
    func defaults() {
        let settings = makeSettings()

        #expect(settings.isEnabled)
        #expect(settings.focusDelayMs == 200)
        #expect(settings.raiseWindow)
        #expect(settings.raiseDelayMs == 0)
        #expect(settings.excludedBundleIDs.isEmpty)
        #expect(!settings.showInDock)
        #expect(settings.isShortcutGuideEnabled)
        #expect(!settings.isSystemHUDEnabled)
        #expect(settings.systemHUDOpacity == 0.82)
        #expect(settings.systemHUDBackgroundBlur == 0.78)
        #expect(settings.systemHUDAppearance == .system)
        #expect(settings.systemHUDRefreshInterval == 2.0)
        #expect(settings.systemHUDPosition == .topTrailing)
        #expect(settings.systemHUDShowsNetwork)
        #expect(!settings.isAgentHUDEnabled)
        #expect(settings.agentHUDLayout == .adaptive)
        #expect(settings.agentHUDRefreshInterval == 3.0)
        #expect(settings.agentHUDShowsTaskDetails)
    }

    @Test("persists changes to UserDefaults")
    func persistence() {
        let suiteName = "test-settings-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.focusDelayMs = 500
        settings.raiseWindow = false
        settings.excludedBundleIDs = ["com.apple.finder"]
        settings.isShortcutGuideEnabled = false
        settings.isSystemHUDEnabled = true
        settings.systemHUDOpacity = 0.7
        settings.systemHUDBackgroundBlur = 0.45
        settings.systemHUDAppearance = .dark
        settings.systemHUDRefreshInterval = 5
        settings.systemHUDPosition = .bottomLeading
        settings.systemHUDShowsNetwork = false
        settings.isAgentHUDEnabled = true
        settings.agentHUDLayout = .stacked
        settings.agentHUDRefreshInterval = 5
        settings.agentHUDShowsTaskDetails = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.focusDelayMs == 500)
        #expect(!reloaded.raiseWindow)
        #expect(reloaded.excludedBundleIDs == ["com.apple.finder"])
        #expect(!reloaded.isShortcutGuideEnabled)
        #expect(reloaded.isSystemHUDEnabled)
        #expect(reloaded.systemHUDOpacity == 0.7)
        #expect(reloaded.systemHUDBackgroundBlur == 0.45)
        #expect(reloaded.systemHUDAppearance == .dark)
        #expect(reloaded.systemHUDRefreshInterval == 5)
        #expect(reloaded.systemHUDPosition == .bottomLeading)
        #expect(!reloaded.systemHUDShowsNetwork)
        #expect(reloaded.isAgentHUDEnabled)
        #expect(reloaded.agentHUDLayout == .stacked)
        #expect(reloaded.agentHUDRefreshInterval == 5)
        #expect(!reloaded.agentHUDShowsTaskDetails)
    }

    @Test("focus delay is clamped to 0 through 1000")
    func focusDelayClamping() {
        let settings = makeSettings()

        settings.focusDelayMs = -50
        #expect(settings.focusDelayMs == 0)

        settings.focusDelayMs = 2000
        #expect(settings.focusDelayMs == 1000)
    }

    @Test("raise delay is clamped to 0 through 500")
    func raiseDelayClamping() {
        let settings = makeSettings()

        settings.raiseDelayMs = -10
        #expect(settings.raiseDelayMs == 0)

        settings.raiseDelayMs = 999
        #expect(settings.raiseDelayMs == 500)
    }

    @Test("HUD settings are clamped to supported values")
    func systemHUDSettingsClamping() {
        let settings = makeSettings()

        settings.systemHUDOpacity = -1
        #expect(settings.systemHUDOpacity == 0.2)
        settings.systemHUDOpacity = 2
        #expect(settings.systemHUDOpacity == 1.0)

        settings.systemHUDBackgroundBlur = -1
        #expect(settings.systemHUDBackgroundBlur == 0)
        settings.systemHUDBackgroundBlur = 2
        #expect(settings.systemHUDBackgroundBlur == 1.0)

        settings.systemHUDRefreshInterval = 0
        #expect(settings.systemHUDRefreshInterval == 1.0)
        settings.systemHUDRefreshInterval = 60
        #expect(settings.systemHUDRefreshInterval == 30.0)

        settings.agentHUDRefreshInterval = 0
        #expect(settings.agentHUDRefreshInterval == 1.0)
        settings.agentHUDRefreshInterval = 60
        #expect(settings.agentHUDRefreshInterval == 30.0)
    }

    private func makeSettings() -> AppSettings {
        let suiteName = "test-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }
}
