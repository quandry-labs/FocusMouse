import ApplicationServices
import Cocoa
import Observation

@MainActor
@Observable
final class WindowFocuser: WindowFocusing {
    private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored var trustDidChange: ((Bool) -> Void)?

    func checkPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        trustDidChange?(trusted)
    }

    /// Poll for permission changes every 2 seconds until granted, then stop.
    func startPollingPermission() {
        guard !isAccessibilityTrusted else { return }
        stopPollingPermission()

        permissionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }

                guard let self else { return }
                self.checkPermission()
                if self.isAccessibilityTrusted {
                    self.permissionTask = nil
                    return
                }
            }
        }
    }

    func stopPollingPermission() {
        permissionTask?.cancel()
        permissionTask = nil
    }

    func focusWindow(_ window: WindowInfo, at point: CGPoint, raiseWindow: Bool) -> Bool {
        guard isAccessibilityTrusted else { return false }
        guard let runningApp = NSRunningApplication(processIdentifier: window.ownerPID),
              !runningApp.isTerminated,
              runningApp.activationPolicy == .regular,
              runningApp.bundleIdentifier == window.ownerBundleID,
              let targetWindow = accessibilityWindow(at: point, expectedPID: window.ownerPID)
        else {
            return false
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        let focusedResult = AXUIElementSetAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            targetWindow
        )
        let mainResult = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let windowFocusResult = AXUIElementSetAttributeValue(
            targetWindow,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        let activated = runningApp.activate()

        var raiseResult: AXError = .success
        if raiseWindow {
            raiseResult = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        }

        let selectedTarget = focusedResult == .success
            || mainResult == .success
            || windowFocusResult == .success
        return activated && selectedTarget && raiseResult == .success
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPollingPermission()
    }

    private func accessibilityWindow(at point: CGPoint, expectedPID: pid_t) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )

        guard hitResult == .success, var element = hitElement else { return nil }

        for _ in 0..<20 {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == expectedPID else {
                return nil
            }

            if copyStringAttribute(kAXRoleAttribute, from: element) == kAXWindowRole {
                return element
            }

            if let window = copyElementAttribute(kAXWindowAttribute, from: element) {
                var windowPID: pid_t = 0
                if AXUIElementGetPid(window, &windowPID) == .success, windowPID == expectedPID {
                    return window
                }
            }

            guard let parent = copyElementAttribute(kAXParentAttribute, from: element) else {
                return nil
            }
            element = parent
        }

        return nil
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
