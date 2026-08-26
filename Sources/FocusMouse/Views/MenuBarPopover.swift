import SwiftUI

struct MenuBarPopover: View {
    @Bindable var settings: AppSettings
    var updater: Updater
    let isAccessibilityGranted: Bool
    let trackingError: String?
    let loginItemEnabled: Bool
    let loginItemError: String?
    let onEnabledChange: (Bool) -> Void
    let onRequestPermission: () -> Void
    let onRetryTracking: () -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onShowInDockChange: (Bool) -> Void
    let onShortcutGuideEnabledChange: (Bool) -> Void
    let onSystemHUDEnabledChange: (Bool) -> Void
    let onSystemHUDSettingsChange: () -> Void
    let onAgentHUDEnabledChange: (Bool) -> Void
    let onAgentHUDSettingsChange: () -> Void
    let onOpenAgentDetails: () -> Void
    let onQuit: () -> Void
    @State private var showExcludedApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionBanner(isGranted: isAccessibilityGranted, onRequest: onRequestPermission)

            Toggle("Enabled", isOn: $settings.isEnabled)
                .font(.headline)
                .onChange(of: settings.isEnabled) { _, enabled in
                    onEnabledChange(enabled)
                }

            if let trackingError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trackingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry Mouse Monitoring", action: onRetryTracking)
                        .font(.caption)
                }
            }

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

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { loginItemEnabled },
                    set: { enabled in onLaunchAtLoginChange(enabled) }
                )
            )

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show in Dock", isOn: $settings.showInDock)
                .onChange(of: settings.showInDock) { _, newValue in
                    onShowInDockChange(newValue)
                }

            Divider()

            Toggle("Command Shortcut Guide", isOn: $settings.isShortcutGuideEnabled)
                .onChange(of: settings.isShortcutGuideEnabled) { _, enabled in
                    onShortcutGuideEnabledChange(enabled)
                }

            Text("Hold ⌘ anywhere, then scroll through macOS defaults and the frontmost app’s native shortcuts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("System HUD", isOn: $settings.isSystemHUDEnabled)
                .onChange(of: settings.isSystemHUDEnabled) { _, enabled in
                    onSystemHUDEnabledChange(enabled)
                }

            Toggle("Agent HUD", isOn: $settings.isAgentHUDEnabled)
                .onChange(of: settings.isAgentHUDEnabled) { _, enabled in
                    onAgentHUDEnabledChange(enabled)
                }

            Button {
                onOpenAgentDetails()
            } label: {
                Label("Open Agent Details…", systemImage: "rectangle.and.text.magnifyingglass")
            }

            if settings.isSystemHUDEnabled || settings.isAgentHUDEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HUD APPEARANCE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    Picker("Anchor", selection: $settings.systemHUDPosition) {
                        ForEach(SystemHUDPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appearance")
                            .foregroundStyle(.secondary)
                        Picker("Appearance", selection: $settings.systemHUDAppearance) {
                            ForEach(SystemHUDAppearance.allCases) { appearance in
                                Text(appearance.label).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("Window opacity")
                        Slider(value: $settings.systemHUDOpacity, in: 0.2...1.0, step: 0.05)
                        Text(settings.systemHUDOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }

                    HStack {
                        Text("Background blur")
                        Slider(value: $settings.systemHUDBackgroundBlur, in: 0...1.0, step: 0.05)
                        Text(settings.systemHUDBackgroundBlur, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }

                    if settings.isSystemHUDEnabled {
                        Picker("System refresh", selection: $settings.systemHUDRefreshInterval) {
                            Text("1 sec").tag(1.0)
                            Text("2 sec").tag(2.0)
                            Text("5 sec").tag(5.0)
                            Text("10 sec").tag(10.0)
                        }

                        Toggle("Show Network Details", isOn: $settings.systemHUDShowsNetwork)
                    }

                    if settings.isAgentHUDEnabled {
                        Divider()

                        Text("AGENT HUD")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)

                        if settings.isSystemHUDEnabled {
                            Picker("HUD layout", selection: $settings.agentHUDLayout) {
                                ForEach(AgentHUDLayout.allCases) { layout in
                                    Text(layout.label).tag(layout)
                                }
                            }
                        }

                        Picker("Agent refresh", selection: $settings.agentHUDRefreshInterval) {
                            Text("1 sec").tag(1.0)
                            Text("3 sec").tag(3.0)
                            Text("5 sec").tag(5.0)
                            Text("10 sec").tag(10.0)
                        }

                        Toggle("Show Task Details", isOn: $settings.agentHUDShowsTaskDetails)
                    }
                }
                .font(.caption)
                .onChange(of: settings.systemHUDPosition) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.systemHUDAppearance) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.systemHUDOpacity) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.systemHUDBackgroundBlur) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.systemHUDRefreshInterval) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.systemHUDShowsNetwork) { _, _ in onSystemHUDSettingsChange() }
                .onChange(of: settings.agentHUDLayout) { _, _ in onAgentHUDSettingsChange() }
                .onChange(of: settings.agentHUDRefreshInterval) { _, _ in onAgentHUDSettingsChange() }
                .onChange(of: settings.agentHUDShowsTaskDetails) { _, _ in onAgentHUDSettingsChange() }
            }

            Divider()

            UpdateView(updater: updater)

            Divider()

            Button("Quit FocusMouse") {
                onQuit()
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
