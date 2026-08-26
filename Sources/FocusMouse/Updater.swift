import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Updater {
    struct ReleaseResponse: Sendable {
        let statusCode: Int
        let finalURL: URL?
    }

    typealias ResponseLoader = @Sendable (URLRequest) async throws -> ReleaseResponse

    static let repoOwner = "quandry-labs"
    static let repoName = "FocusMouse"
    static let latestReleaseURL = URL(
        string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
    )!

    enum State: Equatable {
        case idle
        case checking
        case available(version: String, url: URL)
        case upToDate
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    @ObservationIgnored private let responseLoader: ResponseLoader
    private let installedVersion: String

    var currentVersion: String { installedVersion }

    init(
        session: URLSession = .shared,
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
    ) {
        self.responseLoader = { request in
            let (_, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            return ReleaseResponse(
                statusCode: httpResponse?.statusCode ?? -1,
                finalURL: httpResponse?.url
            )
        }
        self.installedVersion = currentVersion
    }

    init(currentVersion: String, responseLoader: @escaping ResponseLoader) {
        self.responseLoader = responseLoader
        self.installedVersion = currentVersion
    }

    func checkForUpdate() async {
        guard state != .checking else { return }
        state = .checking
        defer { lastChecked = Date() }

        do {
            var request = URLRequest(
                url: Self.latestReleaseURL,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 15
            )
            request.httpMethod = "HEAD"
            request.setValue("FocusMouse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let response = try await responseLoader(request)
            guard (200..<300).contains(response.statusCode),
                  let releaseURL = response.finalURL,
                  let latestVersion = Self.version(fromReleaseURL: releaseURL)
            else {
                state = .error("Could not validate the latest release")
                return
            }

            if Self.isNewer(latestVersion, than: currentVersion) {
                state = .available(version: latestVersion, url: releaseURL)
            } else {
                state = .upToDate
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .error("Update check failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func openReleasePage(_ url: URL) -> Bool {
        guard Self.version(fromReleaseURL: url) != nil else {
            state = .error("Refused an invalid release URL")
            return false
        }

        let opened = NSWorkspace.shared.open(url)
        if !opened {
            state = .error("Could not open the release page")
        }
        return opened
    }

    static func version(fromReleaseURL url: URL) -> String? {
        guard url.scheme == "https",
              url.host?.lowercased() == "github.com"
        else {
            return nil
        }

        let expectedPrefix = "/\(repoOwner)/\(repoName)/releases/tag/"
        guard url.path.hasPrefix(expectedPrefix) else { return nil }

        let tag = String(url.path.dropFirst(expectedPrefix.count))
        guard !tag.isEmpty, !tag.contains("/") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return SemanticVersion(version) == nil ? nil : version
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let remoteVersion = SemanticVersion(remote),
              let localVersion = SemanticVersion(local)
        else {
            return false
        }
        return remoteVersion > localVersion
    }
}

private struct SemanticVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]?

    init?(_ value: String) {
        let withoutBuildMetadata = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let parts = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)

        guard !numberParts.isEmpty,
              numberParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              numberParts.allSatisfy({ $0.count == 1 || $0.first != "0" }),
              numberParts.count <= 4
        else {
            return nil
        }

        let numbers = numberParts.compactMap { Int($0) }
        guard numbers.count == numberParts.count else { return nil }
        self.numbers = numbers

        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
            else {
                return nil
            }
            self.prerelease = identifiers
        } else {
            self.prerelease = nil
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let componentCount = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<componentCount {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(left), .some(right)):
            for index in 0..<max(left.count, right.count) {
                guard index < left.count else { return true }
                guard index < right.count else { return false }

                let leftNumber = Int(left[index])
                let rightNumber = Int(right[index])
                switch (leftNumber, rightNumber) {
                case let (.some(leftValue), .some(rightValue)) where leftValue != rightValue:
                    return leftValue < rightValue
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    if left[index] != right[index] { return left[index] < right[index] }
                }
            }
            return false
        }
    }
}
