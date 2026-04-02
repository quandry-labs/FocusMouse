import SwiftUI

struct UpdateView: View {
    let updater: Updater

    var body: some View {
        switch updater.state {
        case .idle:
            Button("Check for Updates") {
                Task { await updater.checkForUpdate() }
            }
            .font(.caption)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking...").font(.caption).foregroundStyle(.secondary)
            }

        case .upToDate:
            Text("Up to date (v\(updater.currentVersion))")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .available(let version, let url):
            VStack(alignment: .leading, spacing: 4) {
                Text("Update available: v\(version)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Download & Install") {
                    Task { await updater.downloadAndInstall(url: url) }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 100)
                Text("Downloading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") {
                    Task { await updater.checkForUpdate() }
                }
                .font(.caption)
            }
        }
    }
}
