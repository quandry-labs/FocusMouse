import Foundation
import Testing
@testable import FocusMouse

@MainActor
@Suite("Updater")
struct UpdaterTests {
    @Test("accepts only this repository's HTTPS release tag URLs")
    func validatesReleaseURLs() {
        let valid = URL(string: "https://github.com/quandry-labs/FocusMouse/releases/tag/v2.1.0")!
        let wrongHost = URL(string: "https://example.com/quandry-labs/FocusMouse/releases/tag/v2.1.0")!
        let insecure = URL(string: "http://github.com/quandry-labs/FocusMouse/releases/tag/v2.1.0")!
        let wrongRepository = URL(string: "https://github.com/other/FocusMouse/releases/tag/v2.1.0")!
        let nestedPath = URL(string: "https://github.com/quandry-labs/FocusMouse/releases/tag/v2.1.0/files")!

        #expect(Updater.version(fromReleaseURL: valid) == "2.1.0")
        #expect(Updater.version(fromReleaseURL: wrongHost) == nil)
        #expect(Updater.version(fromReleaseURL: insecure) == nil)
        #expect(Updater.version(fromReleaseURL: wrongRepository) == nil)
        #expect(Updater.version(fromReleaseURL: nestedPath) == nil)
    }

    @Test("compares stable and prerelease semantic versions")
    func comparesVersions() {
        #expect(Updater.isNewer("1.2.0", than: "1.1.9"))
        #expect(Updater.isNewer("2.0.0", than: "1.99.99"))
        #expect(Updater.isNewer("1.0.0", than: "1.0.0-beta.2"))
        #expect(!Updater.isNewer("1.0.0-beta.2", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("not-a-version", than: "1.0.0"))
    }

    @Test("check reports a validated newer release")
    func reportsNewRelease() async {
        let releaseURL = URL(
            string: "https://github.com/quandry-labs/FocusMouse/releases/tag/v1.2.0"
        )!
        let updater = Updater(currentVersion: "1.1.0") { request in
            #expect(request.httpMethod == "HEAD")
            return .init(statusCode: 200, finalURL: releaseURL)
        }

        await updater.checkForUpdate()

        #expect(updater.state == .available(version: "1.2.0", url: releaseURL))
        #expect(updater.lastChecked != nil)
    }

    @Test("check rejects an untrusted redirect target")
    func rejectsUntrustedRedirect() async {
        let updater = Updater(currentVersion: "1.1.0") { _ in
            .init(
                statusCode: 200,
                finalURL: URL(string: "https://example.com/releases/tag/v99.0.0")!
            )
        }

        await updater.checkForUpdate()

        #expect(updater.state == .error("Could not validate the latest release"))
    }

    @Test("check reports current and older releases as up to date")
    func reportsUpToDate() async {
        let updater = Updater(currentVersion: "1.2.0") { _ in
            .init(
                statusCode: 200,
                finalURL: URL(
                    string: "https://github.com/quandry-labs/FocusMouse/releases/tag/v1.1.0"
                )!
            )
        }

        await updater.checkForUpdate()

        #expect(updater.state == .upToDate)
    }
}
