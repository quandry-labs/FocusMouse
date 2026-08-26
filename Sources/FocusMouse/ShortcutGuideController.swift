import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
@Observable
final class ShortcutGuideController {
    static let panelWidth: CGFloat = 980
    static let panelHeight: CGFloat = 540
    static let defaultShowDelay: Duration = .milliseconds(650)

    let settings: AppSettings
    private(set) var isVisible = false
    private(set) var isMonitoring = false
    private(set) var pages: [ShortcutGuidePage]
    private(set) var currentPageIndex = 0

    var currentPage: ShortcutGuidePage {
        pages[min(max(0, currentPageIndex), pages.count - 1)]
    }

    @ObservationIgnored private let showDelay: Duration
    @ObservationIgnored private let nativeShortcutProvider: any NativeShortcutProviding
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var globalScrollMonitor: Any?
    @ObservationIgnored private var localScrollMonitor: Any?
    @ObservationIgnored private var screenChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isCommandHeldByItself = false
    @ObservationIgnored private var scrollAccumulator: CGFloat = 0
    @ObservationIgnored private var lastPageChangeTime: TimeInterval = 0

    init(
        settings: AppSettings,
        showDelay: Duration = ShortcutGuideController.defaultShowDelay,
        nativeShortcutProvider: any NativeShortcutProviding = NativeMenuShortcutProvider()
    ) {
        self.settings = settings
        self.showDelay = showDelay
        self.nativeShortcutProvider = nativeShortcutProvider
        self.pages = Self.systemPages()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applySettings()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeMonitors()
        cancelPresentation()
        hideGuide()
        panel = nil
    }

    func applySettings() {
        guard isRunning else { return }
        if settings.isShortcutGuideEnabled {
            installMonitors()
        } else {
            removeMonitors()
            cancelPresentation()
            hideGuide()
        }
    }

    /// Internal so trigger behavior can be tested without synthesizing or
    /// intercepting a real keyboard event.
    func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard isRunning, settings.isShortcutGuideEnabled else { return }

        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let isCommandOnly = flags.intersection(shortcutModifiers) == .command

        guard isCommandOnly else {
            isCommandHeldByItself = false
            cancelPresentation()
            hideGuide()
            return
        }

        guard !isCommandHeldByItself else { return }
        isCommandHeldByItself = true
        schedulePresentation()
    }

    /// Internal for deterministic paging tests and future alternate inputs.
    func movePage(_ direction: ShortcutGuidePageDirection) {
        guard pages.count > 1 else { return }
        switch direction {
        case .previous:
            currentPageIndex = currentPageIndex == 0 ? pages.count - 1 : currentPageIndex - 1
        case .next:
            currentPageIndex = (currentPageIndex + 1) % pages.count
        }
    }

    func handleScroll(deltaY: CGFloat, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isVisible, pages.count > 1 else { return }
        scrollAccumulator += deltaY
        guard abs(scrollAccumulator) >= 12, timestamp - lastPageChangeTime >= 0.16 else { return }

        movePage(scrollAccumulator < 0 ? .next : .previous)
        scrollAccumulator = 0
        lastPageChangeTime = timestamp
    }

    /// Rebuilds all pages from the frontmost app and the complete built-in catalog.
    func reloadShortcutPages() {
        let systemPages = Self.systemPages()
        guard let native = nativeShortcutProvider.frontmostApplicationShortcuts(),
              native.shortcutCount > 0
        else {
            pages = systemPages
            currentPageIndex = 0
            return
        }

        let appPages = ShortcutGuidePaginator.pages(
            sourceID: "native-\(native.bundleIdentifier ?? native.applicationName)",
            eyebrow: native.applicationName.uppercased(),
            title: "Native menu shortcuts",
            sourceDetail: "\(native.shortcutCount) shortcuts from the frontmost app",
            groups: native.groups
        )
        pages = appPages + systemPages
        currentPageIndex = 0
    }

    // Internal so the non-activating, click-through contract can be regression tested.
    func makePanel() -> NSPanel {
        let panel = ClickThroughHUDPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: Self.panelWidth, height: Self.panelHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: ShortcutGuideView(controller: self)
        )
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))
        return panel
    }

    private func installMonitors() {
        guard !isMonitoring else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleModifierFlags(event.modifierFlags)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleModifierFlags(event.modifierFlags)
            }
            return event
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionVisibleGuide()
            }
        }
        isMonitoring = true
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        isMonitoring = false
        isCommandHeldByItself = false
    }

    private func schedulePresentation() {
        cancelPresentation()
        let showDelay = showDelay
        presentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: showDelay)
            } catch {
                return
            }

            guard let self,
                  self.isRunning,
                  self.settings.isShortcutGuideEnabled,
                  self.isCommandHeldByItself
            else {
                return
            }
            self.presentationTask = nil
            self.showGuide()
        }
    }

    private func cancelPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func showGuide() {
        guard let screen = targetScreen() else { return }
        reloadShortcutPages()
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: screen)
        installPagingMonitors()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        isVisible = true
    }

    private func hideGuide() {
        removePagingMonitors()
        guard isVisible else { return }
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        isVisible = false
    }

    private func installPagingMonitors() {
        guard globalScrollMonitor == nil, localScrollMonitor == nil else { return }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScroll(deltaY: event.scrollingDeltaY)
            }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScroll(deltaY: event.scrollingDeltaY)
            }
            return event
        }
        scrollAccumulator = 0
        lastPageChangeTime = 0
    }

    private func removePagingMonitors() {
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        scrollAccumulator = 0
    }

    private func repositionVisibleGuide() {
        guard isVisible, let panel, let screen = targetScreen() else { return }
        position(panel, on: screen)
    }

    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let x = visibleFrame.midX - (size.width / 2)
        let availableVerticalSpace = max(0, visibleFrame.height - size.height)
        let y = visibleFrame.minY + (availableVerticalSpace * 0.28)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func systemPages() -> [ShortcutGuidePage] {
        ShortcutGuidePaginator.pages(
            sourceID: "macos-system",
            eyebrow: "MACOS",
            title: "System and native shortcuts",
            sourceDetail: "\(SystemShortcutCatalog.shortcutCount) Apple-documented defaults",
            groups: SystemShortcutCatalog.groups
        )
    }
}

enum ShortcutGuidePageDirection {
    case previous
    case next
}

private enum ShortcutGuidePalette {
    static let forest = Color(red: 15 / 255, green: 59 / 255, blue: 46 / 255)
    static let emerald = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
    static let celdon = Color(red: 184 / 255, green: 212 / 255, blue: 194 / 255)
}

private struct ShortcutGuideView: View {
    @Bindable var controller: ShortcutGuideController

    var body: some View {
        let page = controller.currentPage

        ShortcutGuideGlassSurface {
            VStack(alignment: .leading, spacing: 18) {
                header(for: page)

                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<ShortcutGuidePaginator.groupsPerPage, id: \.self) { index in
                        if index < page.groups.count {
                            ShortcutGuideGroupView(group: page.groups[index])
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            Color.clear
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                footer(for: page)
            }
            .padding(22)
        }
        .padding(10)
        .frame(
            width: ShortcutGuideController.panelWidth,
            height: ShortcutGuideController.panelHeight
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .preferredColorScheme(.dark)
    }

    private func header(for page: ShortcutGuidePage) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(ShortcutGuidePalette.emerald.opacity(0.24))
                Text("⌘")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShortcutGuidePalette.celdon)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(page.eyebrow)
                        .foregroundStyle(ShortcutGuidePalette.celdon)
                    Text("SHORTCUT GUIDE")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.05)

                Text(page.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }

            Spacer()

            Text("RELEASE TO DISMISS")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(for page: ShortcutGuidePage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
            Text(page.sourceDetail)
            Spacer()
            Image(systemName: "arrow.up.arrow.down")
            Text("SCROLL FOR MORE")
                .fontWeight(.bold)
            Text("\(controller.currentPageIndex + 1) / \(controller.pages.count)")
                .monospacedDigit()
            Text("· RELEASE ⌘ TO DISMISS")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct ShortcutGuideGroupView: View {
    let group: ShortcutGuideGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(group.title, systemImage: group.symbol)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(ShortcutGuidePalette.celdon)
                .padding(.bottom, 8)

            ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                ShortcutGuideRow(shortcut: shortcut)
                    .padding(.vertical, 6)

                if index < group.shortcuts.count - 1 {
                    Divider().opacity(0.45)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ShortcutGuidePalette.forest.opacity(0.48))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ShortcutGuidePalette.celdon.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct ShortcutGuideRow: View {
    let shortcut: ShortcutGuideItem

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 3) {
                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, key.count > 1 ? 7 : 5)
                        .frame(minWidth: 23, minHeight: 23)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.primary.opacity(0.10))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.primary.opacity(0.16), lineWidth: 0.75)
                        }
                }
            }
        }
        .frame(minHeight: 25)
    }
}

private struct ShortcutGuideGlassSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        ZStack {
            ShortcutGuideVisualEffectBackground()
                .clipShape(shape)
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
            shape.fill(ShortcutGuidePalette.forest.opacity(0.18))

            if #available(macOS 26.0, *) {
                shape
                    .fill(.white.opacity(0.001))
                    .glassEffect(
                        .regular.tint(ShortcutGuidePalette.emerald.opacity(0.16)),
                        in: .rect(cornerRadius: 30)
                    )
            }

            content
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(.primary.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ShortcutGuideVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
