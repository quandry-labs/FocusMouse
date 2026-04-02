import SwiftUI

struct MenuBarPopover: View {
    @Bindable var settings: AppSettings
    let isAccessibilityGranted: Bool
    let onRequestPermission: () -> Void
    let onQuit: () -> Void
    @State private var showExcludedApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionBanner(isGranted: isAccessibilityGranted, onRequest: onRequestPermission)

            Toggle("Enabled", isOn: $settings.isEnabled)
                .font(.headline)

            Divider()

            DelaySlider(label: "Focus Delay", value: $settings.focusDelayMs, range: 0...1000, unit: "ms")

            Divider()

            Toggle("Raise Window", isOn: $settings.raiseWindow)

            if settings.raiseWindow {
                DelaySlider(label: "Raise Delay", value: $settings.raiseDelayMs, range: 0...500, unit: "ms")
                    .padding(.leading, 8)
            }

            Divider()

            Button("Excluded Apps (\(settings.excludedBundleIDs.count))...") {
                showExcludedApps = true
            }
            .sheet(isPresented: $showExcludedApps) {
                ExcludedAppsView(excludedBundleIDs: $settings.excludedBundleIDs)
            }

            Divider()

            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                }

            Toggle("Show in Dock", isOn: $settings.showInDock)
                .onChange(of: settings.showInDock) { _, newValue in
                    NSApplication.shared.setActivationPolicy(newValue ? .regular : .accessory)
                }

            Divider()

            Button("Quit FocusMouse") {
                onQuit()
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
