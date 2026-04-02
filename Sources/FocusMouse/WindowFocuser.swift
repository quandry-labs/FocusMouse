import ApplicationServices
import Cocoa
import Observation

@Observable
final class WindowFocuser: WindowFocusing {
    private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    private var pollTimer: Timer?

    func checkPermission() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// Poll for permission changes every 2 seconds until granted, then stop.
    func startPollingPermission() {
        guard !isAccessibilityTrusted else { return }
        stopPollingPermission()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.checkPermission()
            if self.isAccessibilityTrusted {
                timer.invalidate()
                self.pollTimer = nil
            }
        }
    }

    func stopPollingPermission() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func focusWindow(pid: pid_t, raiseWindow: Bool) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)

        let nsApp = NSRunningApplication(processIdentifier: pid)
        nsApp?.activate()

        if raiseWindow {
            var frontWindow: AnyObject?
            let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &frontWindow)
            if windowResult == .success {
                AXUIElementSetAttributeValue(frontWindow as! AXUIElement, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(frontWindow as! AXUIElement, kAXRaiseAction as CFString)
            }
        }

        return true
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPollingPermission()
    }
}
