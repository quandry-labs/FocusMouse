import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentHUDController {
    static let panelWidth: CGFloat = 660
    private static let minimumPanelHeight: CGFloat = 320
    private static let edgeInset: CGFloat = 24
    private static let companionGap: CGFloat = 26

    let settings: AppSettings
    private(set) var snapshot = AgentHUDSnapshot.placeholder

    @ObservationIgnored private let sampler = AgentTelemetrySampler()
    @ObservationIgnored private weak var systemHUD: SystemHUDController?
    @ObservationIgnored private var panels: [CGDirectDisplayID: NSPanel] = [:]
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screenChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var systemHUDFrameObserver: NSObjectProtocol?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isDetailsVisible = false

    init(settings: AppSettings, systemHUD: SystemHUDController) {
        self.settings = settings
        self.systemHUD = systemHUD
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applySettings() }
        }
        systemHUDFrameObserver = NotificationCenter.default.addObserver(
            forName: SystemHUDController.frameDidChangeNotification,
            object: systemHUD,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resizePanels(animated: true) }
        }
        applySettings()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        sampleTask?.cancel()
        sampleTask = nil
        isDetailsVisible = false
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if let systemHUDFrameObserver {
            NotificationCenter.default.removeObserver(systemHUDFrameObserver)
            self.systemHUDFrameObserver = nil
        }
        hidePanels()
    }

    func setVisible(_ visible: Bool) {
        applySettings()
    }

    func setDetailsVisible(_ visible: Bool) {
        guard isDetailsVisible != visible else { return }
        isDetailsVisible = visible
        applySettings()
    }

    func applySettings() {
        guard isRunning else { return }
        restartTimer()
        if settings.isAgentHUDEnabled {
            updatePanels()
        } else {
            hidePanels()
        }

        guard shouldSample else {
            sampleTask?.cancel()
            sampleTask = nil
            return
        }
        refresh()
    }

    // Internal so the same input-pass-through guarantee as the System HUD can
    // be regression tested independently.
    func makePanel() -> NSPanel {
        let panel = ClickThroughHUDPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: Self.panelWidth, height: Self.minimumPanelHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        return panel
    }

    private func restartTimer() {
        timer?.invalidate()
        guard shouldSample else {
            timer = nil
            return
        }
        timer = Timer.scheduledTimer(
            withTimeInterval: settings.agentHUDRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func refresh() {
        guard sampleTask == nil else { return }
        let sampler = sampler
        let showTaskDetails = settings.agentHUDShowsTaskDetails
        sampleTask = Task { [weak self] in
            let snapshot = await sampler.sample(showTaskDetails: showTaskDetails)
            guard let self, !Task.isCancelled else { return }
            let structureChanged = self.snapshot.sessions.count != snapshot.sessions.count
                || self.snapshot.quotas.count != snapshot.quotas.count
            self.snapshot = snapshot
            self.sampleTask = nil
            if structureChanged {
                await Task.yield()
                self.resizePanels(animated: true)
            }
        }
    }

    private var shouldSample: Bool {
        settings.isAgentHUDEnabled || isDetailsVisible
    }

    private func updatePanels() {
        let screens = NSScreen.screens
        let displayIDs = Set(screens.map(\.displayID))
        let obsoleteDisplayIDs = panels.keys.filter { !displayIDs.contains($0) }

        for displayID in obsoleteDisplayIDs {
            panels[displayID]?.orderOut(nil)
            panels.removeValue(forKey: displayID)
        }

        for screen in screens {
            let panel = panels[screen.displayID] ?? makePanel()
            panels[screen.displayID] = panel
            applyVisualSettings(to: panel)
            let hostingView = NSHostingView(rootView: AgentHUDView(controller: self))
            hostingView.sizingOptions = [.intrinsicContentSize]
            panel.contentView = hostingView
            resize(panel: panel, on: screen, animated: false)
            panel.orderFrontRegardless()
        }
    }

    private func applyVisualSettings(to panel: NSPanel) {
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.alphaValue = CGFloat(settings.systemHUDOpacity)
        panel.appearance = switch settings.systemHUDAppearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func resizePanels(animated: Bool) {
        guard settings.isAgentHUDEnabled else { return }
        for screen in NSScreen.screens {
            guard let panel = panels[screen.displayID] else { continue }
            applyVisualSettings(to: panel)
            resize(panel: panel, on: screen, animated: animated)
        }
    }

    private func resize(panel: NSPanel, on screen: NSScreen, animated: Bool) {
        panel.contentView?.invalidateIntrinsicContentSize()
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = panel.contentView?.fittingSize.height ?? Self.minimumPanelHeight
        let size = NSSize(
            width: Self.panelWidth,
            height: max(Self.minimumPanelHeight, ceil(fittingHeight))
        )
        let targetFrame = frame(for: screen, size: size)
        guard panel.frame != targetFrame else { return }
        panel.setFrame(targetFrame, display: true, animate: animated)
    }

    private func frame(for screen: NSScreen, size: NSSize) -> NSRect {
        guard settings.isSystemHUDEnabled,
              let systemFrame = systemHUD?.panelFrame(for: screen.displayID)
        else {
            return anchoredFrame(on: screen, size: size)
        }

        switch settings.agentHUDLayout {
        case .sideBySide:
            return sideBySideFrame(on: screen, size: size, systemFrame: systemFrame)
                ?? stackedFrame(on: screen, size: size, systemFrame: systemFrame)
        case .stacked:
            return stackedFrame(on: screen, size: size, systemFrame: systemFrame)
        case .adaptive:
            return sideBySideFrame(on: screen, size: size, systemFrame: systemFrame)
                ?? stackedFrame(on: screen, size: size, systemFrame: systemFrame)
        }
    }

    private func anchoredFrame(on screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat
        switch settings.systemHUDPosition {
        case .topLeading:
            x = visible.minX + Self.edgeInset
            y = visible.maxY - size.height - Self.edgeInset
        case .topTrailing:
            x = visible.maxX - size.width - Self.edgeInset
            y = visible.maxY - size.height - Self.edgeInset
        case .bottomLeading:
            x = visible.minX + Self.edgeInset
            y = visible.minY + Self.edgeInset
        case .bottomTrailing:
            x = visible.maxX - size.width - Self.edgeInset
            y = visible.minY + Self.edgeInset
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func sideBySideFrame(
        on screen: NSScreen,
        size: NSSize,
        systemFrame: NSRect
    ) -> NSRect? {
        let alignTop = settings.systemHUDPosition == .topLeading || settings.systemHUDPosition == .topTrailing
        let y = alignTop ? systemFrame.maxY - size.height : systemFrame.minY
        let preferredX: CGFloat
        let alternateX: CGFloat

        switch settings.systemHUDPosition {
        case .topLeading, .bottomLeading:
            preferredX = systemFrame.maxX + Self.companionGap
            alternateX = systemFrame.minX - Self.companionGap - size.width
        case .topTrailing, .bottomTrailing:
            preferredX = systemFrame.minX - Self.companionGap - size.width
            alternateX = systemFrame.maxX + Self.companionGap
        }

        for x in [preferredX, alternateX] {
            let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
            if fits(candidate, in: screen.visibleFrame) {
                return candidate
            }
        }
        return nil
    }

    private func stackedFrame(on screen: NSScreen, size: NSSize, systemFrame: NSRect) -> NSRect {
        let visible = screen.visibleFrame
        let isLeading = settings.systemHUDPosition == .topLeading || settings.systemHUDPosition == .bottomLeading
        let isTop = settings.systemHUDPosition == .topLeading || settings.systemHUDPosition == .topTrailing
        let preferredX = isLeading ? systemFrame.minX : systemFrame.maxX - size.width
        let preferredY = isTop
            ? systemFrame.minY - Self.companionGap - size.height
            : systemFrame.maxY + Self.companionGap
        let x = min(max(preferredX, visible.minX + Self.edgeInset), visible.maxX - size.width - Self.edgeInset)
        let y = min(max(preferredY, visible.minY + Self.edgeInset), visible.maxY - size.height - Self.edgeInset)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func fits(_ frame: NSRect, in visibleFrame: NSRect) -> Bool {
        frame.minX >= visibleFrame.minX + Self.edgeInset
            && frame.maxX <= visibleFrame.maxX - Self.edgeInset
            && frame.minY >= visibleFrame.minY + Self.edgeInset
            && frame.maxY <= visibleFrame.maxY - Self.edgeInset
    }

    private func hidePanels() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
    }
}

private enum AgentHUDTokens {
    static let cardCornerRadius: CGFloat = 28
    static let tileCornerRadius: CGFloat = 18
    static let inset: CGFloat = 20
    static let spacing: CGFloat = 12
}

enum AgentHUDPalette {
    static let forest = Color(red: 15 / 255, green: 59 / 255, blue: 46 / 255)
    static let teal = Color(red: 16 / 255, green: 102 / 255, blue: 85 / 255)
    static let emerald = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
    static let celdon = Color(red: 184 / 255, green: 212 / 255, blue: 194 / 255)
    static let sage = Color(red: 105 / 255, green: 183 / 255, blue: 133 / 255)
    static let blue = Color(red: 59 / 255, green: 155 / 255, blue: 120 / 255)
    static let slate = Color(red: 71 / 255, green: 122 / 255, blue: 104 / 255)
    static let mauve = Color(red: 93 / 255, green: 141 / 255, blue: 117 / 255)
    static let amber = Color(nsColor: .systemOrange)
}

private struct AgentHUDView: View {
    @Bindable var controller: AgentHUDController
    @State private var hasAppeared = false

    var body: some View {
        let snapshot = controller.snapshot

        AgentGlassSurface(blurStrength: controller.settings.systemHUDBackgroundBlur) {
            VStack(alignment: .leading, spacing: AgentHUDTokens.spacing) {
                AgentHUDHeader(snapshot: snapshot)

                HStack(alignment: .top, spacing: AgentHUDTokens.spacing) {
                    AgentFleetCard(snapshot: snapshot)
                        .frame(width: 242)
                    AgentTokenFlowCard(snapshot: snapshot)
                }

                AgentSessionsCard(snapshot: snapshot)

                HStack(alignment: .top, spacing: AgentHUDTokens.spacing) {
                    AgentQuotaCard(snapshot: snapshot)
                    AgentTokenBreakdownCard(usage: snapshot.tokenUsage)
                }
            }
            .padding(AgentHUDTokens.inset)
        }
        .frame(width: AgentHUDController.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: hasAppeared)
        .onAppear { hasAppeared = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AgentGlassSurface<Content: View>: View {
    let blurStrength: Double
    let content: Content

    init(blurStrength: Double, @ViewBuilder content: () -> Content) {
        self.blurStrength = blurStrength
        self.content = content()
    }

    var body: some View {
        let strength = min(1, max(0, blurStrength))
        let shape = RoundedRectangle(cornerRadius: AgentHUDTokens.cardCornerRadius, style: .continuous)

        ZStack {
            AgentVisualEffectBackground(strength: strength)
                .clipShape(shape)
            shape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.16 + ((1 - strength) * 0.48)))
            shape
                .fill(AgentHUDPalette.forest.opacity(0.11 + (strength * 0.09)))
            if #available(macOS 26.0, *) {
                shape
                    .fill(.white.opacity(0.001))
                    .glassEffect(
                        .regular.tint(AgentHUDPalette.emerald.opacity(0.15)),
                        in: .rect(cornerRadius: AgentHUDTokens.cardCornerRadius)
                    )
                    .opacity(strength)
            }
            content
        }
        .clipShape(shape)
        .overlay { shape.stroke(.primary.opacity(0.15 + (strength * 0.08)), lineWidth: 1) }
        .animation(.easeOut(duration: 0.22), value: strength)
    }
}

private struct AgentVisualEffectBackground: NSViewRepresentable {
    let strength: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = CGFloat(min(1, max(0, strength)))
    }
}

private struct AgentHUDHeader: View {
    let snapshot: AgentHUDSnapshot

    private var activeCount: Int {
        snapshot.sessions.filter { $0.state == .running }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            AgentAccentIcon(symbol: "cpu.fill", tint: AgentHUDPalette.emerald, size: 40, symbolSize: 17, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("FOCUSMOUSE")
                        .foregroundStyle(AgentHUDPalette.celdon)
                    Text("AGENT HUD")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(1.05)

                Text("AI harness activity")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("\(snapshot.processes.count) processes · \(activeCount) active tasks · sampled \(snapshot.sampledAt, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            AgentLivePill(isActive: !snapshot.processes.isEmpty)
        }
    }
}

private struct AgentLivePill: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
            Text(isActive ? "LIVE" : "IDLE")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(isActive ? AgentHUDPalette.sage : AgentHUDPalette.slate, in: Capsule())
    }
}

private struct AgentTile<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AgentHUDPalette.forest.opacity(0.16),
                in: RoundedRectangle(cornerRadius: AgentHUDTokens.tileCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AgentHUDTokens.tileCornerRadius, style: .continuous)
                    .stroke(AgentHUDPalette.celdon.opacity(0.16), lineWidth: 1)
            }
    }
}

private struct AgentSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                AgentAccentIcon(symbol: icon, tint: tint, size: 32, symbolSize: 14, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.75)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                Capsule().fill(tint).frame(width: 46, height: 3)
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            }
        }
    }
}

private struct AgentAccentIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    let symbolSize: CGFloat
    let cornerRadius: CGFloat

    init(symbol: String, tint: Color, size: CGFloat = 28, symbolSize: CGFloat = 13, cornerRadius: CGFloat = 9) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
        self.symbolSize = symbolSize
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct AgentFleetCard: View {
    let snapshot: AgentHUDSnapshot

    private var harnessCounts: [(AgentHarness, Int)] {
        Dictionary(grouping: snapshot.processes, by: \.harness)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.displayName < $1.0.displayName }
    }

    private var cpuTotal: Double {
        snapshot.processes.reduce(0) { $0 + $1.cpuPercent }
    }

    var body: some View {
        AgentTile {
            VStack(alignment: .leading, spacing: 12) {
                AgentSectionHeader(
                    title: "Harnesses",
                    subtitle: "Local agent processes",
                    icon: "point.3.connected.trianglepath.dotted",
                    tint: AgentHUDPalette.blue
                )

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(snapshot.processes.count)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("RUNNING")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(cpuTotal, format: .number.precision(.fractionLength(1)))% CPU")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if harnessCounts.isEmpty {
                    Text("No supported agent harness is running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(harnessCounts, id: \.0) { harness, count in
                            AgentHarnessChip(harness: harness, count: count)
                        }
                    }
                }
            }
        }
    }
}

private struct AgentHarnessChip: View {
    let harness: AgentHarness
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(harness.tint).frame(width: 6, height: 6)
            Text(harness.displayName)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(harness.tint.opacity(0.1), in: Capsule())
        .overlay { Capsule().stroke(harness.tint.opacity(0.2), lineWidth: 1) }
    }
}

private struct AgentTokenFlowCard: View {
    let snapshot: AgentHUDSnapshot

    var body: some View {
        AgentTile {
            VStack(alignment: .leading, spacing: 10) {
                AgentSectionHeader(
                    title: "Token flow",
                    subtitle: "Rolling observed throughput",
                    icon: "waveform.path.ecg",
                    tint: AgentHUDPalette.sage
                )

                AgentSparkline(values: snapshot.tokenRateHistory)
                    .stroke(
                        LinearGradient(
                            colors: [AgentHUDPalette.sage, AgentHUDPalette.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(height: 42)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(tokenText(snapshot.tokenRate))/s")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("CURRENT RATE")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tokenText(Double(snapshot.tokenUsage.totalTokens)))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("VISIBLE SESSIONS")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AgentSessionsCard: View {
    let snapshot: AgentHUDSnapshot

    var body: some View {
        AgentTile {
            VStack(alignment: .leading, spacing: 11) {
                AgentSectionHeader(
                    title: "Tasks & sessions",
                    subtitle: "Live and recent local work",
                    icon: "list.bullet.rectangle.portrait.fill",
                    tint: AgentHUDPalette.emerald
                )

                if snapshot.sessions.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(AgentHUDPalette.slate)
                        Text("No recent Codex or Claude session telemetry")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 7) {
                        ForEach(snapshot.sessions.prefix(4)) { session in
                            AgentSessionRow(session: session)
                        }
                    }
                }
            }
        }
    }
}

private struct AgentSessionRow: View {
    let session: AgentSessionSnapshot

    var body: some View {
        HStack(spacing: 10) {
            AgentAccentIcon(symbol: session.harness.symbol, tint: session.harness.tint, size: 32, symbolSize: 14, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.taskLabel)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.project)
                    if let branch = session.branch {
                        Text("·")
                        Text(branch)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(shortModel(session.model, effort: session.effort))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(tokenText(Double(session.tokenUsage.totalTokens)))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 118, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 4) {
                AgentStatePill(state: session.state)
                if let context = session.contextFraction {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(.primary.opacity(0.12))
                            .frame(width: 42, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(contextTint(context)).frame(width: 42 * context, height: 4)
                            }
                        Text(context, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(9)
        .background(session.harness.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(session.harness.tint.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct AgentStatePill: View {
    let state: AgentSessionState

    private var tint: Color {
        switch state {
        case .running: AgentHUDPalette.sage
        case .waiting: AgentHUDPalette.amber
        case .idle: AgentHUDPalette.slate
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(state.rawValue.uppercased())
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1), in: Capsule())
    }
}

private struct AgentQuotaCard: View {
    let snapshot: AgentHUDSnapshot

    var body: some View {
        AgentTile {
            VStack(alignment: .leading, spacing: 11) {
                AgentSectionHeader(
                    title: "Quota",
                    subtitle: "Provider-reported windows",
                    icon: "gauge.with.dots.needle.33percent",
                    tint: AgentHUDPalette.amber
                )

                if snapshot.quotas.isEmpty {
                    Text("No quota window reported by active session logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .leading)
                } else {
                    ForEach(snapshot.quotas.prefix(2)) { quota in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(quota.harness.displayName) · \(quota.label)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(quota.usedFraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.weight(.bold).monospacedDigit())
                            }
                            Capsule()
                                .fill(.primary.opacity(0.12))
                                .frame(height: 6)
                                .overlay(alignment: .leading) {
                                    GeometryReader { geometry in
                                        Capsule()
                                            .fill(quotaTint(quota.usedFraction))
                                            .frame(width: geometry.size.width * quota.usedFraction)
                                    }
                                }
                            if let resetDate = quota.resetDate {
                                Text("Resets \(resetDate, style: .relative)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AgentTokenBreakdownCard: View {
    let usage: AgentTokenUsage

    private var rows: [(String, UInt64, Color)] {
        [
            ("Input", usage.inputTokens, AgentHUDPalette.blue),
            ("Cached", usage.cachedInputTokens, AgentHUDPalette.sage),
            ("Output", usage.outputTokens, AgentHUDPalette.amber),
            ("Reasoning", usage.reasoningTokens, AgentHUDPalette.mauve),
        ]
    }

    var body: some View {
        AgentTile {
            VStack(alignment: .leading, spacing: 10) {
                AgentSectionHeader(
                    title: "Token mix",
                    subtitle: "Visible session accounting",
                    icon: "circle.hexagongrid.fill",
                    tint: AgentHUDPalette.blue
                )

                ForEach(rows, id: \.0) { label, value, tint in
                    HStack(spacing: 7) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(label)
                            .font(.caption)
                        Spacer()
                        Text(tokenText(Double(value)))
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                }
            }
        }
    }
}

private struct AgentSparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let maximum = max(values.max() ?? 0, 1)
        let step = rect.width / CGFloat(values.count - 1)
        var path = Path()

        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * step
            let y = rect.maxY - (CGFloat(value / maximum) * rect.height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension AgentHarness {
    var symbol: String {
        switch self {
        case .codex: "terminal.fill"
        case .claude: "sparkles"
        case .gemini: "diamond.fill"
        case .aider: "hammer.fill"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .copilot: "person.2.wave.2.fill"
        case .amp: "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .codex: AgentHUDPalette.emerald
        case .claude: AgentHUDPalette.amber
        case .gemini: AgentHUDPalette.blue
        case .aider: AgentHUDPalette.sage
        case .openCode: AgentHUDPalette.teal
        case .cursor: AgentHUDPalette.mauve
        case .copilot: AgentHUDPalette.slate
        case .amp: AgentHUDPalette.amber
        }
    }
}

private func tokenText(_ value: Double) -> String {
    switch value {
    case 1_000_000_000...: String(format: "%.1fB", value / 1_000_000_000)
    case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
    case 1_000...: String(format: "%.1fK", value / 1_000)
    default: String(Int(value.rounded()))
    }
}

private func shortModel(_ model: String, effort: String?) -> String {
    var shortened = model
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-20251001", with: "")
    if shortened.count > 18 {
        shortened = String(shortened.prefix(18))
    }
    return effort.map { "\(shortened) · \($0)" } ?? shortened
}

private func contextTint(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.65: AgentHUDPalette.sage
    case ..<0.85: AgentHUDPalette.amber
    default: .red
    }
}

private func quotaTint(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.65: AgentHUDPalette.sage
    case ..<0.85: AgentHUDPalette.amber
    default: .red
    }
}
