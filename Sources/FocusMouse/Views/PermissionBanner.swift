import SwiftUI

struct PermissionBanner: View {
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        if !isGranted {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility Permission Required", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("FocusMouse needs Accessibility permission to detect and focus windows under your cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open System Settings") {
                    onRequest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
