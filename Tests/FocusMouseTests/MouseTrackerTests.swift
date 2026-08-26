import CoreGraphics
import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("MouseTracker", .serialized)
struct MouseTrackerTests {
    @Test("event tap excludes every mouse button event")
    func eventTapExcludesClicks() {
        let buttonEvents: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp
        ]

        for type in buttonEvents {
            let eventBit = CGEventMask(1) << type.rawValue
            #expect(MouseTracker.observedEventMask & eventBit == 0)
        }
    }

    @Test("running state matches event tap creation")
    func startStop() {
        let settings = makeSettings()
        let tracker = MouseTracker(settings: settings, focuser: MockWindowFocuser())

        let started = tracker.start()
        #expect(tracker.isRunning == started)

        tracker.stop()
        #expect(!tracker.isRunning)
    }

    @Test("focuses the exact window and point")
    func focusesExactWindow() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 0
        let focuser = MockWindowFocuser()
        let point = CGPoint(x: 100, y: 200)
        let window = makeWindow(id: 42, pid: 123)
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { _, _ in window }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: point)
        try await waitUntil { focuser.focusCalls.count == 1 }

        #expect(focuser.focusCalls == [
            .init(window: window, point: point, raiseWindow: true)
        ])
    }

    @Test("can focus two windows owned by the same process")
    func sameProcessWindows() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 0
        settings.raiseWindow = false
        let focuser = MockWindowFocuser()
        let firstPoint = CGPoint(x: 10, y: 10)
        let secondPoint = CGPoint(x: 500, y: 10)
        let firstWindow = makeWindow(id: 1, pid: 123)
        let secondWindow = makeWindow(id: 2, pid: 123)
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { point, _ in point == firstPoint ? firstWindow : secondWindow }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: firstPoint)
        try await waitUntil { focuser.focusCalls.count == 1 }
        tracker.handlePointerEvent(type: .mouseMoved, location: secondPoint)
        try await waitUntil { focuser.focusCalls.count == 2 }

        #expect(focuser.focusCalls.map(\.window.windowID) == [1, 2])
    }

    @Test("does not focus excluded apps")
    func excludedApps() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 0
        settings.excludedBundleIDs = ["com.example.target"]
        let focuser = MockWindowFocuser()
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { _, _ in makeWindow(id: 1, pid: 123) }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: .zero)
        try await Task.sleep(for: .milliseconds(80))

        #expect(focuser.focusCalls.isEmpty)
    }

    @Test("disabled settings cancel pending focus")
    func disabledCancelsFocus() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 100
        let focuser = MockWindowFocuser()
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { _, _ in makeWindow(id: 1, pid: 123) }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: .zero)
        settings.isEnabled = false
        tracker.handlePointerEvent(type: .mouseMoved, location: .zero)
        try await Task.sleep(for: .milliseconds(180))

        #expect(focuser.focusCalls.isEmpty)
    }

    @Test("dragging cancels pending focus")
    func dragCancelsFocus() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 30
        let focuser = MockWindowFocuser()
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { _, _ in makeWindow(id: 1, pid: 123) }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: .zero)
        tracker.handlePointerEvent(type: .leftMouseDragged, location: .zero)
        try await Task.sleep(for: .milliseconds(80))

        #expect(focuser.focusCalls.isEmpty)
    }

    @Test("delayed raise is canceled after entering an excluded app")
    func excludedAppCancelsDelayedRaise() async throws {
        let settings = makeSettings()
        settings.focusDelayMs = 0
        settings.raiseWindow = true
        settings.raiseDelayMs = 100
        settings.excludedBundleIDs = ["com.example.excluded"]
        let focuser = MockWindowFocuser()
        let targetPoint = CGPoint(x: 10, y: 10)
        let excludedPoint = CGPoint(x: 20, y: 20)
        let targetWindow = makeWindow(id: 1, pid: 123)
        let excludedWindow = makeWindow(id: 2, pid: 456, bundleID: "com.example.excluded")
        let tracker = MouseTracker(
            settings: settings,
            focuser: focuser,
            windowLookup: { point, _ in point == targetPoint ? targetWindow : excludedWindow }
        )

        tracker.handlePointerEvent(type: .mouseMoved, location: targetPoint)
        try await waitUntil { focuser.focusCalls.count == 1 }
        tracker.handlePointerEvent(type: .mouseMoved, location: excludedPoint)
        try await Task.sleep(for: .milliseconds(150))

        #expect(focuser.focusCalls.count == 1)
        if let call = focuser.focusCalls.first {
            #expect(call.window.windowID == targetWindow.windowID)
            #expect(!call.raiseWindow)
        }
    }

    private func makeSettings() -> AppSettings {
        let suiteName = "test-tracker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t,
        bundleID: String = "com.example.target"
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerPID: pid,
            ownerBundleID: bundleID,
            ownerName: "Target",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0,
            isOnScreen: true
        )
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
