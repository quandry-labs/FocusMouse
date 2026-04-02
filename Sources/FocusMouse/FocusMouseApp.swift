import SwiftUI

@main
struct FocusMouseApp: App {
    @State private var settings = AppSettings()
    @State private var focuser = WindowFocuser()
    @State private var tracker: MouseTracker?

    init() {
        let settings = AppSettings()
        if !settings.showInDock {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        LoginItem.setEnabled(settings.launchAtLogin)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(
                settings: settings,
                isAccessibilityGranted: focuser.isAccessibilityTrusted,
                onRequestPermission: { focuser.requestAccessibilityPermission() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .task {
                guard tracker == nil else { return }
                let newTracker = MouseTracker(settings: settings, focuser: focuser)
                tracker = newTracker
                newTracker.start()
            }
        } label: {
            Image(systemName: settings.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}
