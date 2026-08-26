import Foundation

enum AgentHarness: String, CaseIterable, Sendable {
    case codex
    case claude
    case gemini
    case aider
    case openCode
    case cursor
    case copilot
    case amp

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .aider: "Aider"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .amp: "Amp"
        }
    }

    init?(processName: String) {
        switch processName.lowercased() {
        case "codex": self = .codex
        case "claude": self = .claude
        case "gemini": self = .gemini
        case "aider": self = .aider
        case "opencode": self = .openCode
        case "cursor-agent", "cursoragent": self = .cursor
        case "copilot": self = .copilot
        case "amp": self = .amp
        default: return nil
        }
    }
}

struct AgentTokenUsage: Equatable, Sendable {
    var inputTokens: UInt64 = 0
    var cachedInputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var reasoningTokens: UInt64 = 0
    var totalTokens: UInt64 = 0

    static let zero = AgentTokenUsage()

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }
}

struct AgentProcessSnapshot: Identifiable, Equatable, Sendable {
    let id: Int32
    let harness: AgentHarness
    let elapsed: TimeInterval
    let cpuPercent: Double
    let memoryPercent: Double
}

enum AgentSessionState: String, Equatable, Sendable {
    case running
    case waiting
    case idle
}

struct AgentSessionSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let harness: AgentHarness
    let project: String
    let workingDirectory: String
    let taskLabel: String
    let branch: String?
    let model: String
    let effort: String?
    let lastActivity: Date
    let tokenUsage: AgentTokenUsage
    let contextFraction: Double?
    let state: AgentSessionState
}

struct AgentQuotaSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let harness: AgentHarness
    let label: String
    let usedFraction: Double
    let resetDate: Date?
}

struct AgentHUDSnapshot: Equatable, Sendable {
    var sampledAt: Date
    var processes: [AgentProcessSnapshot]
    var sessions: [AgentSessionSnapshot]
    var tokenUsage: AgentTokenUsage
    var quotas: [AgentQuotaSnapshot]
    var tokenRate: Double
    var tokenRateHistory: [Double]

    static let placeholder = AgentHUDSnapshot(
        sampledAt: .now,
        processes: [],
        sessions: [],
        tokenUsage: .zero,
        quotas: [],
        tokenRate: 0,
        tokenRateHistory: Array(repeating: 0, count: 24)
    )
}

actor AgentTelemetrySampler {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private var cachedCodexLogs: [URL] = []
    private var cachedClaudeLogs: [URL] = []
    private var parsedLogCache: [URL: CachedParsedLog] = [:]
    private var nextLogDiscovery = Date.distantPast
    private var previousTokenTotal: UInt64?
    private var previousSampleDate: Date?
    private var tokenRateHistory = Array(repeating: 0.0, count: 24)

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func sample(showTaskDetails: Bool) -> AgentHUDSnapshot {
        let now = Date()
        refreshLogCandidatesIfNeeded(now: now)

        let processes = scanProcesses()
        let runningHarnesses = Set(processes.map(\.harness))
        let reader = AgentSessionLogReader(fileManager: fileManager)

        var parsedSessions: [ParsedAgentSession] = []
        parsedSessions.append(contentsOf: cachedCodexLogs.compactMap { cachedSession(at: $0, harness: .codex, reader: reader) })
        parsedSessions.append(contentsOf: cachedClaudeLogs.compactMap { cachedSession(at: $0, harness: .claude, reader: reader) })
        parsedSessions.sort { $0.session.lastActivity > $1.session.lastActivity }

        var selectedParsed: [ParsedAgentSession] = []
        var selectedIDs = Set<String>()
        for harness in runningHarnesses.sorted(by: { $0.displayName < $1.displayName }) {
            if let representative = parsedSessions.first(where: { $0.session.harness == harness }) {
                selectedParsed.append(representative)
                selectedIDs.insert(representative.session.id)
            }
        }
        for parsed in parsedSessions where selectedParsed.count < 16 && !selectedIDs.contains(parsed.session.id) {
            selectedParsed.append(parsed)
            selectedIDs.insert(parsed.session.id)
        }

        let sessions = selectedParsed.map { parsed -> AgentSessionSnapshot in
            let session = parsed.session
            let age = now.timeIntervalSince(session.lastActivity)
            let state: AgentSessionState
            if runningHarnesses.contains(session.harness), age < 150 {
                state = .running
            } else if runningHarnesses.contains(session.harness), age < 1_200 {
                state = .waiting
            } else {
                state = .idle
            }

            return AgentSessionSnapshot(
                id: session.id,
                harness: session.harness,
                project: session.project,
                workingDirectory: session.workingDirectory,
                taskLabel: showTaskDetails ? session.taskLabel : "Task details hidden",
                branch: session.branch,
                model: session.model,
                effort: session.effort,
                lastActivity: session.lastActivity,
                tokenUsage: session.tokenUsage,
                contextFraction: session.contextFraction,
                state: state
            )
        }

        let tokenUsage = sessions.reduce(.zero) { $0 + $1.tokenUsage }
        let quotas = latestQuotas(from: selectedParsed)
        let tokenRate = updateTokenRate(total: tokenUsage.totalTokens, now: now)

        return AgentHUDSnapshot(
            sampledAt: now,
            processes: processes,
            sessions: sessions,
            tokenUsage: tokenUsage,
            quotas: quotas,
            tokenRate: tokenRate,
            tokenRateHistory: tokenRateHistory
        )
    }

    private func refreshLogCandidatesIfNeeded(now: Date) {
        guard now >= nextLogDiscovery else { return }
        cachedCodexLogs = recentLogs(
            below: homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory),
            limit: 8
        )
        cachedClaudeLogs = recentLogs(
            below: homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory),
            limit: 8
        )
        let retainedURLs = Set(cachedCodexLogs + cachedClaudeLogs)
        parsedLogCache = parsedLogCache.filter { retainedURLs.contains($0.key) }
        nextLogDiscovery = now.addingTimeInterval(30)
    }

    private func cachedSession(
        at url: URL,
        harness: AgentHarness,
        reader: AgentSessionLogReader
    ) -> ParsedAgentSession? {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        if let cached = parsedLogCache[url], cached.modified == modified {
            return cached.session
        }

        let parsed: ParsedAgentSession?
        switch harness {
        case .codex:
            parsed = reader.readCodexSession(url)
        case .claude:
            parsed = reader.readClaudeSession(url)
        default:
            parsed = nil
        }
        if let parsed {
            parsedLogCache[url] = CachedParsedLog(modified: modified, session: parsed)
        }
        return parsed
    }

    private func recentLogs(below directory: URL, limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            candidates.append((url, modified))
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.url)
    }

    private func scanProcesses() -> [AgentProcessSnapshot] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,etime=,%cpu=,%mem=,comm="]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[2]),
                  let memory = Double(fields[3])
            else { return nil }

            let command = String(fields[4])
            let executable = URL(fileURLWithPath: command).lastPathComponent
            guard let harness = AgentHarness(processName: executable) else { return nil }

            return AgentProcessSnapshot(
                id: pid,
                harness: harness,
                elapsed: Self.elapsedTime(String(fields[1])),
                cpuPercent: max(0, cpu),
                memoryPercent: max(0, memory)
            )
        }
        .sorted { lhs, rhs in
            if lhs.harness.displayName == rhs.harness.displayName {
                return lhs.elapsed > rhs.elapsed
            }
            return lhs.harness.displayName < rhs.harness.displayName
        }
    }

    private func latestQuotas(from sessions: [ParsedAgentSession]) -> [AgentQuotaSnapshot] {
        var quotasByID: [String: (date: Date, quota: AgentQuotaSnapshot)] = [:]
        for parsed in sessions {
            for quota in parsed.quotas {
                let existing = quotasByID[quota.id]
                if existing == nil || parsed.session.lastActivity > existing!.date {
                    quotasByID[quota.id] = (parsed.session.lastActivity, quota)
                }
            }
        }
        return quotasByID.values
            .map(\.quota)
            .sorted { $0.label < $1.label }
    }

    private func updateTokenRate(total: UInt64, now: Date) -> Double {
        var rate = 0.0
        if let previousTokenTotal, let previousSampleDate, total >= previousTokenTotal {
            let elapsed = max(0.1, now.timeIntervalSince(previousSampleDate))
            rate = min(Double(total - previousTokenTotal) / elapsed, 5_000_000)
        }

        previousTokenTotal = total
        previousSampleDate = now
        tokenRateHistory.append(rate)
        if tokenRateHistory.count > 30 {
            tokenRateHistory.removeFirst(tokenRateHistory.count - 30)
        }
        return rate
    }

    private static func elapsedTime(_ text: String) -> TimeInterval {
        let dayParts = text.split(separator: "-", maxSplits: 1).map(String.init)
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.count == 2 ? dayParts[1] : dayParts[0])
            .split(separator: ":")
            .compactMap { Double($0) }

        let seconds: Double
        switch clock.count {
        case 3: seconds = (clock[0] * 3_600) + (clock[1] * 60) + clock[2]
        case 2: seconds = (clock[0] * 60) + clock[1]
        case 1: seconds = clock[0]
        default: seconds = 0
        }
        return (days * 86_400) + seconds
    }

    private struct CachedParsedLog: Sendable {
        let modified: Date
        let session: ParsedAgentSession
    }
}

struct ParsedAgentSession: Sendable {
    let session: AgentSessionSnapshot
    let quotas: [AgentQuotaSnapshot]
}

struct AgentSessionLogReader {
    private static let tailByteLimit = 640_000
    private static let headerByteLimit = 96_000

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func readCodexSession(_ url: URL) -> ParsedAgentSession? {
        guard let modified = modificationDate(for: url) else { return nil }
        let headerObjects = jsonObjects(in: data(from: url, byteLimit: Self.headerByteLimit, fromEnd: false))
        let tailObjects = jsonObjects(in: data(from: url, byteLimit: Self.tailByteLimit, fromEnd: true))

        let sessionMeta = headerObjects.first { string($0["type"]) == "session_meta" }
        let meta = dictionary(sessionMeta?["payload"])
        let turn = tailObjects.last { string($0["type"]) == "turn_context" }
        let turnPayload = dictionary(turn?["payload"])

        let cwd = string(turnPayload?["cwd"])
            ?? string(meta?["cwd"])
            ?? url.deletingLastPathComponent().path
        let identifier = string(meta?["id"])
            ?? url.deletingPathExtension().lastPathComponent
        let model = string(turnPayload?["model"]) ?? "Codex"
        let effort = string(turnPayload?["effort"])

        let source = dictionary(meta?["source"])
        let subagent = dictionary(source?["subagent"])
        let spawn = dictionary(subagent?["thread_spawn"])
        let agentPath = string(spawn?["agent_path"])
        let nickname = string(spawn?["agent_nickname"])
        let taskLabel: String
        if let agentPath {
            let component = agentPath.split(separator: "/").last.map(String.init) ?? agentPath
            taskLabel = nickname.map { "\($0) · \(component.replacingOccurrences(of: "_", with: " "))" }
                ?? component.replacingOccurrences(of: "_", with: " ")
        } else {
            taskLabel = "Interactive task"
        }

        let tokenEvent = tailObjects.last { object in
            let payload = dictionary(object["payload"])
            return string(object["type"]) == "event_msg" && string(payload?["type"]) == "token_count"
        }
        let tokenPayload = dictionary(tokenEvent?["payload"])
        let info = dictionary(tokenPayload?["info"])
        let totalUsage = dictionary(info?["total_token_usage"])
        let lastUsage = dictionary(info?["last_token_usage"])
        let contextWindow = double(info?["model_context_window"])
        let contextInput = double(lastUsage?["input_tokens"])
        let contextFraction = contextWindow.flatMap { window in
            contextInput.map { min(1, max(0, $0 / max(1, window))) }
        }

        let usage = AgentTokenUsage(
            inputTokens: uint(totalUsage?["input_tokens"]),
            cachedInputTokens: uint(totalUsage?["cached_input_tokens"]),
            outputTokens: uint(totalUsage?["output_tokens"]),
            reasoningTokens: uint(totalUsage?["reasoning_output_tokens"]),
            totalTokens: uint(totalUsage?["total_tokens"])
        )

        let rateLimits = dictionary(tokenPayload?["rate_limits"])
        let quotas = ["primary", "secondary"].compactMap { key -> AgentQuotaSnapshot? in
            guard let window = dictionary(rateLimits?[key]),
                  let usedPercent = double(window["used_percent"])
            else { return nil }
            let windowMinutes = double(window["window_minutes"]) ?? 0
            let label: String
            if windowMinutes >= 10_000 {
                label = "Weekly quota"
            } else if windowMinutes >= 240 {
                label = "5-hour quota"
            } else if windowMinutes > 0 {
                label = "\(Int(windowMinutes))-minute quota"
            } else {
                label = "Usage quota"
            }
            let resetDate = double(window["resets_at"]).map(Date.init(timeIntervalSince1970:))
            return AgentQuotaSnapshot(
                id: "codex-\(key)",
                harness: .codex,
                label: label,
                usedFraction: min(1, max(0, usedPercent / 100)),
                resetDate: resetDate
            )
        }

        let project = URL(fileURLWithPath: cwd).lastPathComponent.nonempty ?? "Workspace"
        return ParsedAgentSession(
            session: AgentSessionSnapshot(
                id: identifier,
                harness: .codex,
                project: project,
                workingDirectory: cwd,
                taskLabel: taskLabel,
                branch: nil,
                model: model,
                effort: effort,
                lastActivity: modified,
                tokenUsage: usage,
                contextFraction: contextFraction,
                state: .idle
            ),
            quotas: quotas
        )
    }

    func readClaudeSession(_ url: URL) -> ParsedAgentSession? {
        guard let modified = modificationDate(for: url) else { return nil }
        let objects = jsonObjects(in: data(from: url, byteLimit: Self.tailByteLimit, fromEnd: true))
        let assistantObjects = objects.filter { string($0["type"]) == "assistant" }
        guard let latest = assistantObjects.last ?? objects.last else { return nil }

        let latestMessage = dictionary(latest["message"])
        let cwd = string(latest["cwd"]) ?? url.deletingLastPathComponent().path
        let sessionID = string(latest["sessionId"]) ?? url.deletingPathExtension().lastPathComponent
        let model = string(latestMessage?["model"]) ?? "Claude"
        let branch = string(latest["gitBranch"]).flatMap { $0 == "HEAD" ? nil : $0 }

        var usage = AgentTokenUsage.zero
        for object in assistantObjects {
            let message = dictionary(object["message"])
            let rawUsage = dictionary(message?["usage"])
            let input = uint(rawUsage?["input_tokens"])
            let cacheCreation = uint(rawUsage?["cache_creation_input_tokens"])
            let cacheRead = uint(rawUsage?["cache_read_input_tokens"])
            let output = uint(rawUsage?["output_tokens"])
            usage = usage + AgentTokenUsage(
                inputTokens: input,
                cachedInputTokens: cacheCreation + cacheRead,
                outputTokens: output,
                reasoningTokens: 0,
                totalTokens: input + cacheCreation + cacheRead + output
            )
        }

        let latestUsage = dictionary(latestMessage?["usage"])
        let latestContext = double(latestUsage?["input_tokens"])
            .map { $0 + (double(latestUsage?["cache_creation_input_tokens"]) ?? 0) + (double(latestUsage?["cache_read_input_tokens"]) ?? 0) }
        let contextFraction = latestContext.map { min(1, max(0, $0 / 200_000)) }
        let project = URL(fileURLWithPath: cwd).lastPathComponent.nonempty ?? "Workspace"
        let taskLabel = branch.map { "Branch · \($0)" } ?? "Interactive task"

        return ParsedAgentSession(
            session: AgentSessionSnapshot(
                id: sessionID,
                harness: .claude,
                project: project,
                workingDirectory: cwd,
                taskLabel: taskLabel,
                branch: branch,
                model: model,
                effort: nil,
                lastActivity: modified,
                tokenUsage: usage,
                contextFraction: contextFraction,
                state: .idle
            ),
            quotas: []
        )
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func data(from url: URL, byteLimit: Int, fromEnd: Bool) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }

        do {
            let fileLength = try handle.seekToEnd()
            let offset = fromEnd ? fileLength - min(fileLength, UInt64(byteLimit)) : 0
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: byteLimit) ?? Data()
            guard fromEnd, offset > 0, let firstNewline = data.firstIndex(of: 0x0A) else {
                return data
            }
            return data[data.index(after: firstNewline)...]
        } catch {
            return Data()
        }
    }

    private func jsonObjects(in data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) else { return nil }
            return object as? [String: Any]
        }
    }

    private func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        (value as? String)?.nonempty
    }

    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func uint(_ value: Any?) -> UInt64 {
        guard let value = double(value), value.isFinite, value > 0 else { return 0 }
        return UInt64(value.rounded())
    }
}

private extension String {
    var nonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
