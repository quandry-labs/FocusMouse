import Foundation
import Testing
@testable import FocusMouse

@Suite("MouseTracker")
struct MouseTrackerTests {
    @Test("starts and stops without crashing")
    func startStop() {
        let defaults = UserDefaults(suiteName: "test-tracker-startstop")!
        defaults.removePersistentDomain(forName: "test-tracker-startstop")
        let settings = AppSettings(defaults: defaults)
        let focuser = MockWindowFocuser()
        let tracker = MouseTracker(settings: settings, focuser: focuser)

        tracker.start()
        #expect(tracker.isRunning == true)

        tracker.stop()
        #expect(tracker.isRunning == false)
    }

    @Test("does not crash when disabled in settings")
    func respectsDisabled() {
        let defaults = UserDefaults(suiteName: "test-tracker-disabled")!
        defaults.removePersistentDomain(forName: "test-tracker-disabled")
        let settings = AppSettings(defaults: defaults)
        settings.isEnabled = false
        let focuser = MockWindowFocuser()
        let tracker = MouseTracker(settings: settings, focuser: focuser)

        tracker.start()
        #expect(tracker.isRunning == true)
        tracker.stop()
    }

    @Test("skips excluded bundle IDs")
    func excludedApps() {
        let defaults = UserDefaults(suiteName: "test-tracker-excluded")!
        defaults.removePersistentDomain(forName: "test-tracker-excluded")
        let settings = AppSettings(defaults: defaults)
        settings.excludedBundleIDs = ["com.apple.finder"]

        #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
    }
}
