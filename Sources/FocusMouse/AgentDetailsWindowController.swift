import AppKit
import SwiftUI

@MainActor
final class AgentDetailsWindowController: NSObject, NSWindowDelegate {
    private let agentHUD: AgentHUDController
    private let settings: AppSettings
    private var window: NSWindow?

    init(agentHUD: AgentHUDController, settings: AppSettings) {
        self.agentHUD = agentHUD
        self.settings = settings
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        applyAppearance(to: window)
        agentHUD.setDetailsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        agentHUD.setDetailsVisible(false)
    }

    // Internal for regression testing the details window's intentionally
    // interactive behavior independently of the click-through desktop HUD.
    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FocusMouse Agent Details"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.setFrameAutosaveName("FocusMouse.AgentDetailsWindow")
        window.contentViewController = NSHostingController(
            rootView: AgentDetailsView(controller: agentHUD, settings: settings)
        )
        applyAppearance(to: window)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        agentHUD.setDetailsVisible(false)
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = switch settings.systemHUDAppearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct AgentDetailsView: View {
    @Bindable var controller: AgentHUDController
    @Bindable var settings: AppSettings

    private var snapshot: AgentHUDSnapshot { controller.snapshot }
    private var activeSessions: Int { snapshot.sessions.filter { $0.state == .running }.count }
    private var totalCPU: Double { snapshot.processes.reduce(0) { $0 + $1.cpuPercent } }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    AgentHUDPalette.forest.opacity(0.24),
                    AgentHUDPalette.teal.opacity(0.10),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    summary
                    processesSection
                    sessionsSection
                    quotasSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .textSelection(.enabled)
        .onChange(of: settings.agentHUDShowsTaskDetails) { _, _ in
            controller.applySettings()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            detailsIcon("point.3.connected.trianglepath.dotted", tint: AgentHUDPalette.emerald, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("FOCUSMOUSE")
                        .foregroundStyle(AgentHUDPalette.celdon)
                    Text("AGENT DETAILS")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                Text("Tasks, sessions, harnesses, tokens and quota")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Live local telemetry · refreshed \(snapshot.sampledAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Show task details", isOn: $settings.agentHUDShowsTaskDetails)
                .toggleStyle(.switch)
                .font(.caption.weight(.semibold))
        }
    }

    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { summaryCards }
            VStack(spacing: 12) { summaryCards }
        }
    }

    @ViewBuilder
    private var summaryCards: some View {
        DetailsMetricCard(
            title: "PROCESSES",
            value: "\(snapshot.processes.count)",
            detail: "\(totalCPU.formatted(.number.precision(.fractionLength(1))))% combined CPU",
            icon: "cpu.fill",
            tint: AgentHUDPalette.blue
        )
        DetailsMetricCard(
            title: "ACTIVE TASKS",
            value: "\(activeSessions)",
            detail: "\(snapshot.sessions.count) recent sessions loaded",
            icon: "list.bullet.rectangle.portrait.fill",
            tint: AgentHUDPalette.emerald
        )
        DetailsMetricCard(
            title: "TOKENS",
            value: compactNumber(snapshot.tokenUsage.totalTokens),
            detail: "\(compactNumber(UInt64(max(0, snapshot.tokenRate)))) / second",
            icon: "circle.hexagongrid.fill",
            tint: AgentHUDPalette.sage
        )
        DetailsMetricCard(
            title: "QUOTA WINDOWS",
            value: "\(snapshot.quotas.count)",
            detail: quotaSummary,
            icon: "gauge.with.dots.needle.33percent",
            tint: AgentHUDPalette.amber
        )
    }

    private var processesSection: some View {
        DetailsSection(
            title: "RUNNING HARNESSES",
            subtitle: "Every supported local agent process",
            icon: "terminal.fill",
            tint: AgentHUDPalette.blue
        ) {
            if snapshot.processes.isEmpty {
                DetailsEmptyState(message: "No supported agent harness is currently running")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(snapshot.processes.enumerated()), id: \.element.id) { index, process in
                        HStack(spacing: 12) {
                            detailsIcon(process.harness.symbol, tint: process.harness.tint, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.harness.displayName)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Text("PID \(process.id)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            DetailsLabeledValue(label: "ELAPSED", value: elapsedText(process.elapsed))
                            DetailsLabeledValue(label: "CPU", value: "\(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))%")
                            DetailsLabeledValue(label: "MEMORY", value: "\(process.memoryPercent.formatted(.number.precision(.fractionLength(1))))%")
                        }
                        .padding(.vertical, 10)
                        if index < snapshot.processes.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        DetailsSection(
            title: "TASKS & SESSIONS",
            subtitle: "Full details for the 16 most recent Codex and Claude logs",
            icon: "rectangle.stack.fill",
            tint: AgentHUDPalette.emerald
        ) {
            if snapshot.sessions.isEmpty {
                DetailsEmptyState(message: "No recent Codex or Claude session telemetry")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(snapshot.sessions) { session in
                        AgentSessionDetailsCard(
                            session: session,
                            revealsDetails: settings.agentHUDShowsTaskDetails
                        )
                    }
                }
            }
        }
    }

    private var quotasSection: some View {
        DetailsSection(
            title: "QUOTA WINDOWS",
            subtitle: "All provider-reported usage windows found in recent logs",
            icon: "chart.bar.fill",
            tint: AgentHUDPalette.amber
        ) {
            if snapshot.quotas.isEmpty {
                DetailsEmptyState(message: "No quota data was reported by recent session logs")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(snapshot.quotas) { quota in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("\(quota.harness.displayName) · \(quota.label)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Spacer()
                                if let resetDate = quota.resetDate {
                                    Text("Resets \(resetDate, style: .relative)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(quota.usedFraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(.primary.opacity(0.10))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(detailsUsageTint(quota.usedFraction))
                                            .frame(width: geometry.size.width * min(1, max(0, quota.usedFraction)))
                                    }
                            }
                            .frame(height: 7)
                        }
                    }
                }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch settings.systemHUDAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var quotaSummary: String {
        guard let highest = snapshot.quotas.max(by: { $0.usedFraction < $1.usedFraction }) else {
            return "No provider data"
        }
        return "Highest \(highest.usedFraction.formatted(.percent.precision(.fractionLength(0)))) used"
    }
}

private struct DetailsMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            detailsIcon(icon, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .detailsCard(tint: tint)
    }
}

private struct DetailsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                detailsIcon(icon, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.7)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
        }
        .padding(16)
        .detailsCard(tint: tint)
    }
}

private struct AgentSessionDetailsCard: View {
    let session: AgentSessionSnapshot
    let revealsDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                detailsIcon(session.harness.symbol, tint: session.harness.tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.taskLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text("\(session.harness.displayName) · \(session.project)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DetailsStatePill(state: session.state)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    DetailsField(label: "MODEL", value: modelText)
                    DetailsField(label: "BRANCH", value: revealsDetails ? (session.branch ?? "—") : "Hidden")
                    DetailsField(label: "LAST ACTIVITY", value: session.lastActivity.formatted(.relative(presentation: .named)))
                }
                GridRow {
                    DetailsField(
                        label: "WORKING DIRECTORY",
                        value: revealsDetails ? session.workingDirectory : "Path hidden",
                        spansColumns: true
                    )
                    .gridCellColumns(3)
                }
            }

            HStack(spacing: 18) {
                DetailsLabeledValue(label: "INPUT", value: exactNumber(session.tokenUsage.inputTokens))
                DetailsLabeledValue(label: "CACHED", value: exactNumber(session.tokenUsage.cachedInputTokens))
                DetailsLabeledValue(label: "OUTPUT", value: exactNumber(session.tokenUsage.outputTokens))
                DetailsLabeledValue(label: "REASONING", value: exactNumber(session.tokenUsage.reasoningTokens))
                Spacer()
                DetailsLabeledValue(label: "TOTAL TOKENS", value: exactNumber(session.tokenUsage.totalTokens))
            }

            if let context = session.contextFraction {
                HStack(spacing: 8) {
                    Text("CONTEXT")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.primary.opacity(0.10))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(detailsUsageTint(context))
                                    .frame(width: geometry.size.width * min(1, max(0, context)))
                            }
                    }
                    .frame(height: 6)
                    Text(context, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(13)
        .background(session.harness.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(session.harness.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var modelText: String {
        session.effort.map { "\(session.model) · \($0)" } ?? session.model
    }
}

private struct DetailsField: View {
    let label: String
    let value: String
    var spansColumns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(spansColumns ? 2 : 1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailsLabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        }
        .frame(minWidth: 64, alignment: .trailing)
    }
}

private struct DetailsStatePill: View {
    let state: AgentSessionState

    private var tint: Color {
        switch state {
        case .running: AgentHUDPalette.sage
        case .waiting: AgentHUDPalette.amber
        case .idle: AgentHUDPalette.slate
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(state.rawValue.uppercased())
        }
        .font(.system(size: 8.5, weight: .bold, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct DetailsEmptyState: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(AgentHUDPalette.slate)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private extension View {
    func detailsCard(tint: Color) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
    }
}

private func detailsIcon(_ symbol: String, tint: Color, size: CGFloat) -> some View {
    Image(systemName: symbol)
        .font(.system(size: size * 0.40, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(tint, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .stroke(.white.opacity(0.24), lineWidth: 1)
        }
}

private func compactNumber(_ value: UInt64) -> String {
    switch value {
    case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1_000_000_000)
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: exactNumber(value)
    }
}

private func exactNumber(_ value: UInt64) -> String {
    value.formatted(.number.grouping(.automatic))
}

private func elapsedText(_ interval: TimeInterval) -> String {
    let totalMinutes = Int(interval) / 60
    if totalMinutes >= 1_440 {
        return "\(totalMinutes / 1_440)d \((totalMinutes % 1_440) / 60)h"
    }
    if totalMinutes >= 60 {
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
    return "\(totalMinutes)m"
}

private func detailsUsageTint(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.65: AgentHUDPalette.sage
    case ..<0.85: AgentHUDPalette.amber
    default: .red
    }
}
