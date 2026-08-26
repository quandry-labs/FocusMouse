import Foundation
import Testing
@testable import FocusMouse

@Suite("Agent telemetry")
struct AgentTelemetryTests {
    @Test("parses Codex token, context, task, and quota telemetry")
    func parsesCodexSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "rollout.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"codex-session","cwd":"/tmp/focusmouse","source":{"subagent":{"thread_spawn":{"agent_path":"/root/build_hud","agent_nickname":"Ada"}}}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol","cwd":"/tmp/focusmouse","effort":"high"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200},"last_token_usage":{"input_tokens":800},"model_context_window":4000},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1900000000}}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let parsed = try #require(AgentSessionLogReader().readCodexSession(log))
        #expect(parsed.session.id == "codex-session")
        #expect(parsed.session.project == "focusmouse")
        #expect(parsed.session.taskLabel == "Ada · build hud")
        #expect(parsed.session.model == "gpt-5.6-sol")
        #expect(parsed.session.effort == "high")
        #expect(parsed.session.tokenUsage.totalTokens == 1200)
        #expect(parsed.session.contextFraction == 0.2)
        #expect(parsed.quotas.first?.label == "5-hour quota")
        #expect(parsed.quotas.first?.usedFraction == 0.25)
    }

    @Test("parses Claude model, branch, and usage telemetry")
    func parsesClaudeSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "session.jsonl")
        let line = #"{"type":"assistant","sessionId":"claude-session","cwd":"/tmp/focusmouse","gitBranch":"feat/agent-hud","message":{"model":"claude-opus-4-1","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}"#
        try line.write(to: log, atomically: true, encoding: .utf8)

        let parsed = try #require(AgentSessionLogReader().readClaudeSession(log))
        #expect(parsed.session.id == "claude-session")
        #expect(parsed.session.taskLabel == "Branch · feat/agent-hud")
        #expect(parsed.session.model == "claude-opus-4-1")
        #expect(parsed.session.tokenUsage.cachedInputTokens == 500)
        #expect(parsed.session.tokenUsage.totalTokens == 650)
        #expect(parsed.session.contextFraction == 0.003)
        #expect(parsed.quotas.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FocusMouse-AgentTelemetry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
