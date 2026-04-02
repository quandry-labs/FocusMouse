import SwiftUI

@main
struct FocusMouseApp: App {
    @State private var settings = AppSettings()
    @State private var focuser = WindowFocuser()
    @State private var tracker: MouseTracker?
    @State private var updater = Updater()

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
                updater: updater,
                isAccessibilityGranted: focuser.isAccessibilityTrusted,
                onRequestPermission: { focuser.requestAccessibilityPermission() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .task {
                startTracker()
                focuser.startPollingPermission()
                await updater.checkForUpdate()
            }
            .onChange(of: focuser.isAccessibilityTrusted) { _, granted in
                if granted {
                    // Recreate the event tap now that we have permission
                    tracker?.stop()
                    tracker = nil
                    startTracker()
                }
            }
        } label: {
            Image(systemName: settings.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }

    private func startTracker() {
        guard tracker == nil else { return }
        let newTracker = MouseTracker(settings: settings, focuser: focuser)
        tracker = newTracker
        newTracker.start()
    }
}
