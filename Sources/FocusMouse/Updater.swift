import AppKit
import Foundation
import Observation

/// Lightweight self-updater that checks GitHub releases for newer versions.
/// Downloads the DMG, mounts it, replaces the app, and relaunches.
@Observable
final class Updater {
    // Configure this to your GitHub repo
    static let repoOwner = "quandry-labs"
    static let repoName = "FocusMouse"
    static let releasesURL = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    enum State: Equatable {
        case idle
        case checking
        case available(version: String, url: String)
        case downloading(progress: Double)
        case installing
        case upToDate
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check for updates

    func checkForUpdate() async {
        state = .checking
        defer { lastChecked = Date() }

        guard let url = URL(string: Self.releasesURL) else {
            state = .error("Invalid release URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                state = .error("GitHub API returned non-200 status")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                state = .error("Could not parse release info")
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard isNewer(latestVersion, than: currentVersion) else {
                state = .upToDate
                return
            }

            // Find the DMG asset
            let dmgAsset = assets.first { asset in
                (asset["name"] as? String)?.hasSuffix(".dmg") == true
            }

            guard let downloadURL = dmgAsset?["browser_download_url"] as? String else {
                state = .error("No DMG found in release \(latestVersion)")
                return
            }

            state = .available(version: latestVersion, url: downloadURL)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Download and install

    func downloadAndInstall(url downloadURLString: String) async {
        guard let downloadURL = URL(string: downloadURLString) else {
            state = .error("Invalid download URL")
            return
        }

        state = .downloading(progress: 0)

        do {
            // Download to temp
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("FocusMouse-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dmgPath = tempDir.appendingPathComponent("FocusMouse.dmg")

            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
            try FileManager.default.moveItem(at: localURL, to: dmgPath)

            state = .installing

            // Mount the DMG
            let mountPoint = tempDir.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            let mountProcess = Process()
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProcess.arguments = ["attach", dmgPath.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"]
            try mountProcess.run()
            mountProcess.waitUntilExit()

            guard mountProcess.terminationStatus == 0 else {
                state = .error("Failed to mount DMG")
                return
            }

            defer {
                // Unmount
                let unmount = Process()
                unmount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                unmount.arguments = ["detach", mountPoint.path, "-quiet"]
                try? unmount.run()
                unmount.waitUntilExit()
                // Cleanup temp
                try? FileManager.default.removeItem(at: tempDir)
            }

            // Find the .app in the mounted DMG
            let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                state = .error("No .app found in DMG")
                return
            }

            // Replace the current app
            guard let currentAppURL = Bundle.main.bundleURL as URL? else {
                state = .error("Cannot determine current app location")
                return
            }

            // Use a staging path next to the current app
            let parent = currentAppURL.deletingLastPathComponent()
            let stagingURL = parent.appendingPathComponent("FocusMouse-new.app")
            let backupURL = parent.appendingPathComponent("FocusMouse-old.app")

            // Copy new app to staging
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.copyItem(at: appBundle, to: stagingURL)

            // Swap: current → backup, staging → current
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: currentAppURL, to: backupURL)
            try FileManager.default.moveItem(at: stagingURL, to: currentAppURL)

            // Clean up backup
            try? FileManager.default.removeItem(at: backupURL)

            // Relaunch
            relaunch(at: currentAppURL)

        } catch {
            state = .error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private func relaunch(at appURL: URL) {
        // Use open to relaunch after a brief delay
        let script = """
        sleep 1
        open "\(appURL.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()

        // Exit the current instance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(self)
        }
    }
}
