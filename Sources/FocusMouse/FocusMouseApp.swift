import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let focuser: WindowFocuser
    let updater: Updater
    let shortcutGuide: ShortcutGuideController
    let systemHUD: SystemHUDController
    let agentHUD: AgentHUDController
    let agentDetails: AgentDetailsWindowController

    private(set) var loginItemEnabled = false
    private(set) var loginItemError: String?
    private(set) var trackingError: String?

    @ObservationIgnored private var tracker: MouseTracker?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(
        settings: AppSettings = AppSettings(),
        focuser: WindowFocuser = WindowFocuser(),
        updater: Updater = Updater()
    ) {
        self.settings = settings
        self.focuser = focuser
        self.updater = updater
        self.shortcutGuide = ShortcutGuideController(settings: settings)
        let systemHUD = SystemHUDController(settings: settings)
        self.systemHUD = systemHUD
        let agentHUD = AgentHUDController(settings: settings, systemHUD: systemHUD)
        self.agentHUD = agentHUD
        self.agentDetails = AgentDetailsWindowController(agentHUD: agentHUD, settings: settings)

        focuser.trustDidChange = { [weak self] trusted in
            self?.accessibilityTrustDidChange(trusted)
        }
    }

    func start() {
        loginItemEnabled = LoginItem.isEnabled
        applyDockVisibility()

        if settings.isEnabled {
            startTrackingIfPossible()
        }
        if !focuser.isAccessibilityTrusted {
            focuser.startPollingPermission()
        }
        shortcutGuide.start()
        systemHUD.start()
        agentHUD.start()

        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await self?.updater.checkForUpdate()
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        focuser.stopPollingPermission()
        tracker?.stop()
        tracker = nil
        shortcutGuide.stop()
        agentDetails.close()
        agentHUD.stop()
        systemHUD.stop()
    }

    func setTrackingEnabled(_ enabled: Bool) {
        if enabled {
            startTrackingIfPossible()
        } else {
            tracker?.stop()
            trackingError = nil
        }
    }

    func retryTracking() {
        tracker?.stop()
        startTrackingIfPossible()
    }

    func requestAccessibilityPermission() {
        focuser.requestAccessibilityPermission()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch LoginItem.setEnabled(enabled) {
        case .success:
            loginItemEnabled = LoginItem.isEnabled
            if enabled && !loginItemEnabled {
                loginItemError = "Approval is required in System Settings > General > Login Items."
            } else {
                loginItemError = nil
            }
        case .failure(let error):
            loginItemEnabled = LoginItem.isEnabled
            loginItemError = error.localizedDescription
        }
    }

    func setShowInDock(_ showInDock: Bool) {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func setShortcutGuideEnabled(_ enabled: Bool) {
        shortcutGuide.applySettings()
    }

    func setSystemHUDEnabled(_ enabled: Bool) {
        systemHUD.setVisible(enabled)
        agentHUD.applySettings()
    }

    func applySystemHUDSettings() {
        systemHUD.applySettings()
        agentHUD.applySettings()
    }

    func setAgentHUDEnabled(_ enabled: Bool) {
        agentHUD.setVisible(enabled)
    }

    func applyAgentHUDSettings() {
        agentHUD.applySettings()
    }

    func showAgentDetails() {
        agentDetails.show()
    }

    private func applyDockVisibility() {
        setShowInDock(settings.showInDock)
    }

    private func accessibilityTrustDidChange(_ trusted: Bool) {
        if trusted, settings.isEnabled {
            startTrackingIfPossible()
        } else if !trusted {
            tracker?.stop()
        }
    }

    private func startTrackingIfPossible() {
        guard focuser.isAccessibilityTrusted else {
            trackingError = nil
            focuser.startPollingPermission()
            return
        }

        let tracker = tracker ?? MouseTracker(settings: settings, focuser: focuser)
        self.tracker = tracker
        trackingError = tracker.start()
            ? nil
            : "Mouse monitoring could not start. Re-enable Accessibility permission and retry."
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        model.setShowInDock(model.settings.showInDock)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

@main
@MainActor
struct FocusMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(
                settings: appDelegate.model.settings,
                updater: appDelegate.model.updater,
                isAccessibilityGranted: appDelegate.model.focuser.isAccessibilityTrusted,
                trackingError: appDelegate.model.trackingError,
                loginItemEnabled: appDelegate.model.loginItemEnabled,
                loginItemError: appDelegate.model.loginItemError,
                onEnabledChange: appDelegate.model.setTrackingEnabled,
                onRequestPermission: appDelegate.model.requestAccessibilityPermission,
                onRetryTracking: appDelegate.model.retryTracking,
                onLaunchAtLoginChange: appDelegate.model.setLaunchAtLogin,
                onShowInDockChange: appDelegate.model.setShowInDock,
                onShortcutGuideEnabledChange: appDelegate.model.setShortcutGuideEnabled,
                onSystemHUDEnabledChange: appDelegate.model.setSystemHUDEnabled,
                onSystemHUDSettingsChange: appDelegate.model.applySystemHUDSettings,
                onAgentHUDEnabledChange: appDelegate.model.setAgentHUDEnabled,
                onAgentHUDSettingsChange: appDelegate.model.applyAgentHUDSettings,
                onOpenAgentDetails: appDelegate.model.showAgentDetails,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            Image(
                systemName: appDelegate.model.settings.isEnabled
                    ? "cursorarrow.motionlines"
                    : "cursorarrow"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
