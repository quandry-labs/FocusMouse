import ApplicationServices
import Cocoa

final class WindowFocuser: WindowFocusing {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func focusWindow(pid: pid_t, raiseWindow: Bool) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)

        // Activate the application
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
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as CFString
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
