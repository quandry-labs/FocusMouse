import SwiftUI

struct ExcludedAppsView: View {
    @Binding var excludedBundleIDs: [String]
    @State private var runningApps: [(name: String, bundleID: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded Apps")
                .font(.headline)

            Text("These apps will be ignored by focus-follows-mouse.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !excludedBundleIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(appName(for: bundleID))
                                .font(.body)
                            Spacer()
                            Button(role: .destructive) {
                                excludedBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
                Divider()
            }

            Text("Running Apps")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(runningApps.filter { !excludedBundleIDs.contains($0.bundleID) },
                            id: \.bundleID) { app in
                        HStack {
                            Text(app.name)
                                .font(.body)
                            Spacer()
                            Button {
                                excludedBundleIDs.append(app.bundleID)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.green)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .frame(width: 300)
        .onAppear { refreshRunningApps() }
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName, let bundleID = app.bundleIdentifier else {
                    return nil
                }
                return (name: name, bundleID: bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName ?? bundleID
    }
}
