import AppKit
import Darwin
import Observation
import SwiftUI

enum SoftwareUpdateStatus: Equatable, Sendable {
    case checking
    case upToDate
    case available(count: Int, title: String?)
    case unavailable
}

struct SystemHUDSnapshot: Equatable, Sendable {
    let hostname: String
    let operatingSystem: String
    let uptime: TimeInterval
    let cpuUsage: Double?
    let perCoreCPUUsage: [Double]
    let memoryUsed: UInt64?
    let physicalMemory: UInt64
    let diskFree: UInt64?
    let diskTotal: UInt64?
    let networkReceiveRate: Double?
    let networkTransmitRate: Double?
    let lanIPv4: String?
    let lanIPv6: String?
    let vpnInterface: String?
    let vpnAddress: String?
    let publicIPv4: String?
    let publicIPv6: String?
    let loggedInUser: String
    let username: String
    let operatingSystemBuild: String?
    let hardwareTelemetry: HardwareTelemetrySample
    var networkReceiveHistory: [Double]
    var networkTransmitHistory: [Double]
    var softwareUpdateStatus: SoftwareUpdateStatus

    static let placeholder = SystemHUDSnapshot(
        hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        operatingSystem: "macOS",
        uptime: ProcessInfo.processInfo.systemUptime,
        cpuUsage: nil,
        perCoreCPUUsage: [],
        memoryUsed: nil,
        physicalMemory: ProcessInfo.processInfo.physicalMemory,
        diskFree: nil,
        diskTotal: nil,
        networkReceiveRate: nil,
        networkTransmitRate: nil,
        lanIPv4: nil,
        lanIPv6: nil,
        vpnInterface: nil,
        vpnAddress: nil,
        publicIPv4: nil,
        publicIPv6: nil,
        loggedInUser: NSFullUserName(),
        username: NSUserName(),
        operatingSystemBuild: nil,
        hardwareTelemetry: .placeholder,
        networkReceiveHistory: [],
        networkTransmitHistory: [],
        softwareUpdateStatus: .checking
    )
}

actor SystemMetricsSampler {
    private struct CPUCounters: Sendable {
        let busy: UInt64
        let total: UInt64
    }

    private struct NetworkCounters: Sendable {
        let received: UInt64
        let transmitted: UInt64
    }

    private struct InterfaceAddress: Sendable {
        let name: String
        let family: Int32
        let address: String
    }

    private struct LocalNetworkState: Sendable {
        let lanIPv4: String?
        let lanIPv6: String?
        let vpnInterface: String?
        let vpnAddress: String?
    }

    private var previousCPU: [CPUCounters]?
    private var previousNetwork: (counters: NetworkCounters, date: Date)?
    private var lastPublicAddressAttempt: Date?
    private var previousVPNInterface: String?
    private var cachedPublicIPv4: String?
    private var cachedPublicIPv6: String?
    private let hardwareTelemetryReader = HardwareTelemetryReader()

    func sample(includeNetworkDetails: Bool) async -> SystemHUDSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let memory = memoryUsage()
        let disk = diskUsage()
        let network = networkRates()
        let processor = processorUsage()
        let hardwareTelemetry = hardwareTelemetryReader.sample()
        let localNetwork = includeNetworkDetails ? localNetworkState() : nil

        if localNetwork?.vpnInterface != previousVPNInterface {
            previousVPNInterface = localNetwork?.vpnInterface
            lastPublicAddressAttempt = nil
        }
        let publicAddresses = includeNetworkDetails
            ? await publicAddresses()
            : (ipv4: cachedPublicIPv4, ipv6: cachedPublicIPv6)

        return SystemHUDSnapshot(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            operatingSystem: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuUsage: processor.overall,
            perCoreCPUUsage: processor.perCore,
            memoryUsed: memory.used,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            diskFree: disk.free,
            diskTotal: disk.total,
            networkReceiveRate: network.received,
            networkTransmitRate: network.transmitted,
            lanIPv4: localNetwork?.lanIPv4,
            lanIPv6: localNetwork?.lanIPv6,
            vpnInterface: localNetwork?.vpnInterface,
            vpnAddress: localNetwork?.vpnAddress,
            publicIPv4: publicAddresses.ipv4,
            publicIPv6: publicAddresses.ipv6,
            loggedInUser: NSFullUserName(),
            username: NSUserName(),
            operatingSystemBuild: systemBuildVersion(),
            hardwareTelemetry: hardwareTelemetry,
            networkReceiveHistory: [],
            networkTransmitHistory: [],
            softwareUpdateStatus: .checking
        )
    }

    private func processorUsage() -> (overall: Double?, perCore: [Double]) {
        guard let current = cpuCounters() else { return (nil, []) }
        defer { previousCPU = current }

        guard let previous = previousCPU, previous.count == current.count else {
            return (nil, [])
        }

        var totalBusyDelta: UInt64 = 0
        var totalDelta: UInt64 = 0
        let perCore = zip(current, previous).map { pair -> Double in
            let (currentCore, previousCore) = pair
            guard currentCore.total >= previousCore.total,
                  currentCore.busy >= previousCore.busy,
                  currentCore.total > previousCore.total
            else {
                return 0
            }
            let busyDelta = currentCore.busy - previousCore.busy
            let coreTotalDelta = currentCore.total - previousCore.total
            totalBusyDelta += busyDelta
            totalDelta += coreTotalDelta
            return min(1, max(0, Double(busyDelta) / Double(coreTotalDelta)))
        }

        guard totalDelta > 0 else { return (nil, perCore) }
        return (
            min(1, max(0, Double(totalBusyDelta) / Double(totalDelta))),
            perCore
        )
    }

    private func cpuCounters() -> [CPUCounters]? {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: processorInfo),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(processorCount)).map { processorIndex in
            let offset = processorIndex * Int(CPU_STATE_MAX)
            let user = UInt64(processorInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            return CPUCounters(
                busy: user + system + nice,
                total: user + system + nice + idle
            )
        }
    }

    private func systemBuildVersion() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func memoryUsage() -> (used: UInt64?, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (nil, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let freePages = UInt64(statistics.free_count) + UInt64(statistics.speculative_count)
        let free = freePages * UInt64(pageSize)
        return (total > free ? total - free : 0, total)
    }

    private func diskUsage() -> (free: UInt64?, total: UInt64?) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (nil, nil)
        }
        let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
        let total = (attributes[.systemSize] as? NSNumber)?.uint64Value
        return (free, total)
    }

    private func networkRates() -> (received: Double?, transmitted: Double?) {
        guard let current = networkCounters() else { return (nil, nil) }
        let now = Date()
        defer { previousNetwork = (current, now) }

        guard let previous = previousNetwork else { return (nil, nil) }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0,
              current.received >= previous.counters.received,
              current.transmitted >= previous.counters.transmitted
        else {
            return (nil, nil)
        }

        return (
            Double(current.received - previous.counters.received) / elapsed,
            Double(current.transmitted - previous.counters.transmitted) / elapsed
        )
    }

    private func networkCounters() -> NetworkCounters? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var transmitted: UInt64 = 0
        var interface: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let data = current.pointee.ifa_data
            else {
                continue
            }

            let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(interfaceData.ifi_ibytes)
            transmitted += UInt64(interfaceData.ifi_obytes)
        }

        return NetworkCounters(received: received, transmitted: transmitted)
    }

    private func localNetworkState() -> LocalNetworkState {
        let addresses = interfaceAddresses()
        let lanAddresses = addresses
            .filter { !isVPNInterface($0.name) && isLANInterface($0.name) }
            .sorted { interfacePriority($0.name) < interfacePriority($1.name) }
        let vpnAddresses = addresses.filter { isVPNInterface($0.name) }
        let vpnInterface = vpnAddresses.first?.name
        let vpnAddress = vpnInterface.flatMap { name in
            vpnAddresses
                .filter { $0.name == name }
                .map(\.address)
                .uniqued()
                .prefix(2)
                .joined(separator: " · ")
        }

        return LocalNetworkState(
            lanIPv4: lanAddresses.first { $0.family == AF_INET }?.address,
            lanIPv6: lanAddresses.first { $0.family == AF_INET6 }?.address,
            vpnInterface: vpnInterface,
            vpnAddress: vpnAddress?.isEmpty == false ? vpnAddress : nil
        )
    }

    private func interfaceAddresses() -> [InterfaceAddress] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var result: [InterfaceAddress] = []
        var interface: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0,
                  flags & Int32(IFF_LOOPBACK) == 0,
                  let socketAddress = current.pointee.ifa_addr
            else {
                continue
            }

            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = host.withUnsafeMutableBufferPointer { buffer in
                getnameinfo(
                    socketAddress,
                    socklen_t(socketAddress.pointee.sa_len),
                    buffer.baseAddress,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard status == 0 else { continue }

            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: hostBytes, as: UTF8.self)
                .components(separatedBy: "%").first ?? ""
            guard !address.isEmpty,
                  !address.hasPrefix("169.254."),
                  !address.lowercased().hasPrefix("fe80:")
            else {
                continue
            }

            result.append(
                InterfaceAddress(
                    name: String(cString: current.pointee.ifa_name),
                    family: family,
                    address: address
                )
            )
        }
        return result
    }

    private func isVPNInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
    }

    private func isLANInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    private func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        return 2
    }

    private func publicAddresses() async -> (ipv4: String?, ipv6: String?) {
        if let lastPublicAddressAttempt,
           Date().timeIntervalSince(lastPublicAddressAttempt) < 300
        {
            return (cachedPublicIPv4, cachedPublicIPv6)
        }

        lastPublicAddressAttempt = Date()
        async let ipv4 = fetchPublicAddress(
            from: URL(string: "https://api.ipify.org")!,
            family: AF_INET
        )
        async let ipv6 = fetchPublicAddress(
            from: URL(string: "https://api6.ipify.org")!,
            family: AF_INET6
        )
        let refreshed = await (ipv4, ipv6)
        cachedPublicIPv4 = refreshed.0 ?? cachedPublicIPv4
        cachedPublicIPv6 = refreshed.1 ?? cachedPublicIPv6
        return (cachedPublicIPv4, cachedPublicIPv6)
    }

    private func fetchPublicAddress(from url: URL, family: Int32) async -> String? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              data.count <= 128,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isIPAddress(value, family: family)
        else {
            return nil
        }
        return value
    }

    private func isIPAddress(_ value: String, family: Int32) -> Bool {
        var storage = in6_addr()
        return value.withCString { inet_pton(family, $0, &storage) == 1 }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

actor SoftwareUpdateChecker {
    private var cachedStatus: SoftwareUpdateStatus?

    func check() async -> SoftwareUpdateStatus {
        if let cachedStatus { return cachedStatus }

        let status = await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            process.arguments = ["--list", "--no-scan"]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return SoftwareUpdateStatus.unavailable
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                return SoftwareUpdateStatus.unavailable
            }
            if text.localizedCaseInsensitiveContains("No new software available") {
                return SoftwareUpdateStatus.upToDate
            }

            let labels = text
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("* Label:") }
            guard !labels.isEmpty else { return SoftwareUpdateStatus.unavailable }
            let firstTitle = labels.first?
                .components(separatedBy: "* Label:")
                .last?
                .trimmingCharacters(in: .whitespaces)
            return SoftwareUpdateStatus.available(count: labels.count, title: firstTitle)
        }.value

        cachedStatus = status
        return status
    }
}

/// A desktop HUD must never activate FocusMouse or become a mouse target.
/// `ignoresMouseEvents` performs the actual WindowServer-level pass-through;
/// these overrides also prevent accidental key/main-window promotion.
@MainActor
final class ClickThroughHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class SystemHUDController {
    static let panelWidth: CGFloat = 840
    static let frameDidChangeNotification = Notification.Name("FocusMouse.SystemHUDFrameDidChange")
    private static let minimumPanelHeight: CGFloat = 248
    private static let edgeInset: CGFloat = 24

    let settings: AppSettings
    private(set) var snapshot = SystemHUDSnapshot.placeholder

    @ObservationIgnored private let sampler = SystemMetricsSampler()
    @ObservationIgnored private let softwareUpdateChecker = SoftwareUpdateChecker()
    @ObservationIgnored private var panels: [CGDirectDisplayID: NSPanel] = [:]
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var softwareUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screenChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var isRunning = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettings()
            }
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
        softwareUpdateTask?.cancel()
        softwareUpdateTask = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        hidePanels()
    }

    func setVisible(_ visible: Bool) {
        // The setting is persisted before this callback runs. Re-applying it also
        // invalidates the sampler timer when the HUD has just been disabled.
        applySettings()
    }

    func panelFrame(for displayID: CGDirectDisplayID) -> NSRect? {
        guard settings.isSystemHUDEnabled else { return nil }
        return panels[displayID]?.frame
    }

    func applySettings() {
        guard isRunning else { return }
        restartTimer()
        guard settings.isSystemHUDEnabled else {
            hidePanels()
            return
        }
        updatePanels()
        refresh()
        refreshSoftwareUpdateStatus()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard settings.isSystemHUDEnabled else {
            timer = nil
            return
        }
        timer = Timer.scheduledTimer(
            withTimeInterval: settings.systemHUDRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func refresh() {
        guard sampleTask == nil else { return }
        let sampler = sampler
        sampleTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await sampler.sample(
                includeNetworkDetails: self.settings.systemHUDShowsNetwork
            )
            guard !Task.isCancelled else { return }
            var mergedSnapshot = snapshot
            mergedSnapshot.softwareUpdateStatus = self.snapshot.softwareUpdateStatus
            mergedSnapshot.networkReceiveHistory = self.appendingHistory(
                self.snapshot.networkReceiveHistory,
                value: snapshot.networkReceiveRate
            )
            mergedSnapshot.networkTransmitHistory = self.appendingHistory(
                self.snapshot.networkTransmitHistory,
                value: snapshot.networkTransmitRate
            )
            self.snapshot = mergedSnapshot
            self.sampleTask = nil
        }
    }

    private func refreshSoftwareUpdateStatus() {
        if softwareUpdateTask == nil {
            let softwareUpdateChecker = softwareUpdateChecker
            softwareUpdateTask = Task { [weak self] in
                let status = await softwareUpdateChecker.check()
                guard let self, !Task.isCancelled else { return }
                var updated = self.snapshot
                updated.softwareUpdateStatus = status
                self.snapshot = updated
                self.softwareUpdateTask = nil
                await Task.yield()
                self.resizePanels(animated: true)
            }
        }
    }

    private func appendingHistory(_ history: [Double], value: Double?) -> [Double] {
        var updated = history
        updated.append(max(0, value ?? 0))
        if updated.count > 30 {
            updated.removeFirst(updated.count - 30)
        }
        return updated
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
            let hostingView = NSHostingView(rootView: SystemHUDView(controller: self))
            hostingView.sizingOptions = [.intrinsicContentSize]
            panel.contentView = hostingView
            resize(panel: panel, on: screen, animated: false)
            panel.orderFrontRegardless()
        }
    }

    // Internal so the input-pass-through contract can be regression tested.
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

    private func applyVisualSettings(to panel: NSPanel) {
        // Reassert click-through whenever visual settings rebuild the hosting
        // view. This prevents future appearance work from making the HUD hit-testable.
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
        for screen in NSScreen.screens {
            guard let panel = panels[screen.displayID] else { continue }
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
        NotificationCenter.default.post(
            name: Self.frameDidChangeNotification,
            object: self,
            userInfo: ["displayID": screen.displayID]
        )
    }

    private func frame(for screen: NSScreen, size: NSSize) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat

        switch settings.systemHUDPosition {
        case .topLeading:
            x = visibleFrame.minX + Self.edgeInset
            y = visibleFrame.maxY - size.height - Self.edgeInset
        case .topTrailing:
            x = visibleFrame.maxX - size.width - Self.edgeInset
            y = visibleFrame.maxY - size.height - Self.edgeInset
        case .bottomLeading:
            x = visibleFrame.minX + Self.edgeInset
            y = visibleFrame.minY + Self.edgeInset
        case .bottomTrailing:
            x = visibleFrame.maxX - size.width - Self.edgeInset
            y = visibleFrame.minY + Self.edgeInset
        }

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func hidePanels() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private enum HUDTokens {
    static let cardCornerRadius: CGFloat = 28
    static let tileCornerRadius: CGFloat = 18
    static let cardInset: CGFloat = 20
    static let spacing: CGFloat = 12
}

private enum HUDPalette {
    // Quandry's forest/emerald/celdon family is the visual foundation. The
    // derived mid-tones retain separation without turning the HUD fluorescent.
    static let quandryForest = Color(red: 15 / 255, green: 59 / 255, blue: 46 / 255)
    static let quandryTeal = Color(red: 16 / 255, green: 102 / 255, blue: 85 / 255)
    static let quandryEmerald = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
    static let quandryCeldon = Color(red: 184 / 255, green: 212 / 255, blue: 194 / 255)
    static let quandryWarmWhite = Color(red: 244 / 255, green: 237 / 255, blue: 224 / 255)

    static let slate = Color(red: 71 / 255, green: 122 / 255, blue: 104 / 255)
    static let blue = Color(red: 59 / 255, green: 155 / 255, blue: 120 / 255)
    static let sage = Color(red: 105 / 255, green: 183 / 255, blue: 133 / 255)
    static let amber = Color(nsColor: .systemOrange)
    static let mauve = Color(red: 93 / 255, green: 141 / 255, blue: 117 / 255)
}

private struct SystemHUDView: View {
    @Bindable var controller: SystemHUDController
    @State private var hasAppeared = false

    var body: some View {
        let snapshot = controller.snapshot

        HUDGlassSurface(
            tint: HUDPalette.quandryEmerald,
            blurStrength: controller.settings.systemHUDBackgroundBlur
        ) {
            VStack(alignment: .leading, spacing: HUDTokens.spacing) {
                HUDHeader(snapshot: snapshot)

                HStack(alignment: .top, spacing: HUDTokens.spacing) {
                    CPUVisualizationCard(snapshot: snapshot)
                        .frame(width: 488)
                    NetworkVisualizationCard(snapshot: snapshot)
                }

                HardwareTelemetryCard(telemetry: snapshot.hardwareTelemetry)

                HStack(alignment: .top, spacing: HUDTokens.spacing) {
                    SystemIdentityCard(snapshot: snapshot)
                    StorageInsightsCard(snapshot: snapshot)
                }

                if controller.settings.systemHUDShowsNetwork {
                    NetworkSection(
                        snapshot: snapshot,
                        received: rateText(snapshot.networkReceiveRate),
                        transmitted: rateText(snapshot.networkTransmitRate)
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(HUDTokens.cardInset)
        }
        .frame(width: SystemHUDController.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: hasAppeared)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: controller.settings.systemHUDShowsNetwork)
        .onAppear {
            hasAppeared = true
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "Sampling…" }
        return "\(byteText(UInt64(bytesPerSecond)))/s"
    }

    private func byteText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

private struct HUDGlassSurface<Content: View>: View {
    let tint: Color
    let blurStrength: Double
    let content: Content

    init(tint: Color, blurStrength: Double, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.blurStrength = blurStrength
        self.content = content()
    }

    var body: some View {
        let strength = min(1, max(0, blurStrength))
        let shape = RoundedRectangle(cornerRadius: HUDTokens.cardCornerRadius, style: .continuous)

        ZStack {
            HUDVisualEffectBackground(strength: strength)
                .clipShape(shape)

            shape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.16 + ((1 - strength) * 0.48)))

            shape
                .fill(HUDPalette.quandryForest.opacity(0.11 + (strength * 0.09)))

            if #available(macOS 26.0, *) {
                shape
                    .fill(.white.opacity(0.001))
                    .glassEffect(
                        .regular.tint(tint.opacity(0.15)),
                        in: .rect(cornerRadius: HUDTokens.cardCornerRadius)
                    )
                    .opacity(strength)
            }

            content
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(.primary.opacity(0.15 + (strength * 0.08)), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.22), value: strength)
    }
}

private struct HUDVisualEffectBackground: NSViewRepresentable {
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

private struct HUDHeader: View {
    let snapshot: SystemHUDSnapshot

    var body: some View {
        HStack(spacing: 12) {
            HUDAccentIcon(
                symbol: "chart.line.uptrend.xyaxis",
                tint: HUDPalette.quandryEmerald,
                size: 40,
                symbolSize: 17,
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("FOCUSMOUSE")
                        .foregroundStyle(HUDPalette.quandryCeldon)
                    Text("SYSTEM HUD")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(1.05)

                Text(snapshot.hostname)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("\(snapshot.operatingSystem) · up \(uptimeText(snapshot.uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            HUDLivePill()
        }
    }

    private func uptimeText(_ uptime: TimeInterval) -> String {
        let totalMinutes = Int(uptime) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}

private struct HUDLivePill: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(HUDPalette.sage, in: Capsule())
    }
}

private struct CPUHero: View {
    let usage: Double?

    private var normalizedUsage: Double { min(1, max(0.03, usage ?? 0.03)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.16), lineWidth: 9)
            Circle()
                .trim(from: 0, to: normalizedUsage)
                .stroke(
                    HUDPalette.blue,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(usage.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("CPU")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 82)
    }
}

private struct HUDSectionSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HUDPalette.quandryForest.opacity(0.16),
            in: RoundedRectangle(cornerRadius: HUDTokens.tileCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: HUDTokens.tileCornerRadius, style: .continuous)
                .stroke(HUDPalette.quandryCeldon.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct HUDSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                HUDAccentIcon(symbol: icon, tint: tint, size: 32, symbolSize: 14, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.75)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                Capsule()
                    .fill(tint)
                    .frame(width: 46, height: 3)
                Rectangle()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 1)
            }
        }
    }
}

private struct HUDAccentIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    let symbolSize: CGFloat
    let cornerRadius: CGFloat

    init(
        symbol: String,
        tint: Color,
        size: CGFloat = 28,
        symbolSize: CGFloat = 13,
        cornerRadius: CGFloat = 9
    ) {
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

private struct CPUVisualizationCard: View {
    let snapshot: SystemHUDSnapshot

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HUDSectionHeader(
                    title: "Processor",
                    subtitle: coreSubtitle,
                    icon: "cpu",
                    tint: HUDPalette.blue
                )

                HStack(alignment: .top, spacing: 16) {
                    CPUHero(usage: snapshot.cpuUsage)
                    CoreUsageGrid(usages: snapshot.perCoreCPUUsage)
                }

                Spacer(minLength: 0)

                HUDProgressRow(
                    title: "Memory",
                    value: memoryText,
                    progress: memoryFraction,
                    tint: HUDPalette.mauve
                )
            }
            .frame(minHeight: 258, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    private var coreSubtitle: String {
        guard !snapshot.perCoreCPUUsage.isEmpty else { return "Sampling logical cores" }
        return "\(snapshot.perCoreCPUUsage.count) logical cores · live utilization"
    }

    private var memoryFraction: Double {
        guard let used = snapshot.memoryUsed, snapshot.physicalMemory > 0 else { return 0 }
        return min(1, Double(used) / Double(snapshot.physicalMemory))
    }

    private var memoryText: String {
        guard let used = snapshot.memoryUsed else { return "Sampling…" }
        return "\(byteText(used)) / \(byteText(snapshot.physicalMemory))"
    }

    private func byteText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

private struct CoreUsageGrid: View {
    let usages: [Double]

    var body: some View {
        if usages.isEmpty {
            VStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Sampling cores")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
        } else {
            let indexedUsages = Array(usages.enumerated())
            let splitIndex = (indexedUsages.count + 1) / 2

            HStack(alignment: .top, spacing: 14) {
                coreColumn(Array(indexedUsages.prefix(splitIndex)))
                coreColumn(Array(indexedUsages.dropFirst(splitIndex)))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func coreColumn(_ entries: [(offset: Int, element: Double)]) -> some View {
        VStack(spacing: 7) {
            ForEach(entries, id: \.offset) { index, usage in
                CoreUsageMeter(index: index, usage: usage)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CoreUsageMeter: View {
    let index: Int
    let usage: Double

    var body: some View {
        HStack(spacing: 6) {
            Text("C\(index + 1)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isActive(segment) ? segmentTint(segment) : .primary.opacity(0.11))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 8)

            Text(usage, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueTint)
                .contentTransition(.numericText())
                .frame(width: 31, alignment: .trailing)
        }
        .frame(height: 12)
    }

    private var activeSegmentCount: Int {
        Int(ceil(min(1, max(0, usage)) * 10))
    }

    private func isActive(_ segment: Int) -> Bool {
        segment < activeSegmentCount
    }

    private func segmentTint(_ segment: Int) -> Color {
        switch segment {
        case 0..<5: HUDPalette.sage
        case 5..<8: HUDPalette.amber
        default: Color(nsColor: .systemRed)
        }
    }

    private var valueTint: Color {
        switch usage {
        case 0..<0.55: HUDPalette.sage
        case 0.55..<0.8: HUDPalette.amber
        default: Color(nsColor: .systemRed)
        }
    }
}

private struct NetworkVisualizationCard: View {
    let snapshot: SystemHUDSnapshot

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HUDSectionHeader(
                    title: "Network activity",
                    subtitle: "Rolling activity history",
                    icon: "waveform.path.ecg",
                    tint: HUDPalette.sage
                )

                NetworkWaveChart(
                    received: snapshot.networkReceiveHistory,
                    transmitted: snapshot.networkTransmitHistory
                )
                .frame(height: 174)

                HStack(spacing: 18) {
                    NetworkRateLegend(
                        title: "Down",
                        value: rateText(snapshot.networkReceiveRate),
                        icon: "arrow.down",
                        tint: HUDPalette.blue
                    )
                    NetworkRateLegend(
                        title: "Up",
                        value: rateText(snapshot.networkTransmitRate),
                        icon: "arrow.up",
                        tint: HUDPalette.sage
                    )
                }
            }
            .frame(minHeight: 258, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    private func rateText(_ value: Double?) -> String {
        guard let value else { return "Sampling…" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary))/s"
    }
}

private struct NetworkWaveChart: View {
    let received: [Double]
    let transmitted: [Double]

    var body: some View {
        GeometryReader { proxy in
            let scale = max(received.max() ?? 0, transmitted.max() ?? 0, 1)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        Rectangle()
                            .fill(.primary.opacity(index == 3 ? 0 : 0.055))
                            .frame(height: 1)
                        if index < 3 { Spacer() }
                    }
                }

                areaPath(values: received, size: proxy.size, scale: scale)
                    .fill(
                        LinearGradient(
                            colors: [HUDPalette.blue.opacity(0.36), HUDPalette.blue.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                linePath(values: received, size: proxy.size, scale: scale)
                    .stroke(HUDPalette.blue, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                linePath(values: transmitted, size: proxy.size, scale: scale)
                    .stroke(HUDPalette.sage, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func linePath(values: [Double], size: CGSize, scale: Double) -> Path {
        Path { path in
            guard !values.isEmpty else { return }
            for (index, value) in values.enumerated() {
                let x = values.count == 1 ? size.width : size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - (size.height * CGFloat(min(1, max(0, value / scale))))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func areaPath(values: [Double], size: CGSize, scale: Double) -> Path {
        var path = linePath(values: values, size: size, scale: scale)
        guard !values.isEmpty else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

private struct NetworkRateLegend: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            HUDAccentIcon(symbol: icon, tint: tint, size: 22, symbolSize: 10, cornerRadius: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct HardwareTelemetryCard: View {
    let telemetry: HardwareTelemetrySample

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HUDSectionHeader(
                    title: "Thermals & power",
                    subtitle: "Live hardware sensors · acoustics estimated from fan speed",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: heatTint
                )

                HStack(alignment: .top, spacing: 10) {
                    TelemetryMetricTile(
                        title: "System heat",
                        value: temperatureText,
                        detail: "\(thermalTitle) thermal pressure",
                        footnote: telemetry.temperatureCelsius == nil ? "Temperature sensor unavailable" : "CPU die sensor",
                        icon: "thermometer.high",
                        tint: heatTint,
                        progress: temperatureProgress
                    )

                    TelemetryMetricTile(
                        title: "Power draw",
                        value: powerText,
                        detail: powerDetail,
                        footnote: "Instantaneous system estimate",
                        icon: "bolt.fill",
                        tint: HUDPalette.amber,
                        progress: nil
                    )

                    TelemetryMetricTile(
                        title: "Fans & acoustics",
                        value: fanSpeedText,
                        detail: fanDetail,
                        footnote: fanFootnote,
                        icon: "fan.fill",
                        tint: HUDPalette.blue,
                        progress: telemetry.fan?.utilization
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var thermalTitle: String {
        return switch telemetry.thermalCondition {
        case .nominal: "Nominal"
        case .fair: "Elevated"
        case .serious: "Serious"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    private var heatTint: Color {
        switch telemetry.thermalCondition {
        case .nominal: HUDPalette.sage
        case .fair: HUDPalette.amber
        case .serious, .critical: Color(nsColor: .systemRed)
        case .unknown: HUDPalette.slate
        }
    }

    private var temperatureText: String {
        guard let temperature = telemetry.temperatureCelsius else { return thermalTitle }
        return String(format: "%.0f °C", temperature)
    }

    private var temperatureProgress: Double {
        if let temperature = telemetry.temperatureCelsius {
            return min(1, max(0, (temperature - 35) / 70))
        }
        return switch telemetry.thermalCondition {
        case .nominal: 0.12
        case .fair: 0.48
        case .serious: 0.76
        case .critical: 1
        case .unknown: 0
        }
    }

    private var powerText: String {
        guard let watts = telemetry.systemPowerWatts else { return "Unavailable" }
        return String(format: watts >= 100 ? "%.0f W" : "%.1f W", watts)
    }

    private var powerDetail: String {
        switch telemetry.powerSource {
        case .smcTotal: "Total board power"
        case .systemLoad: "Live system load"
        case nil: "Sensor unavailable"
        }
    }

    private var fanSpeedText: String {
        guard let fan = telemetry.fan else { return "No reading" }
        return "\(Int(fan.averageRPM.rounded()).formatted()) RPM"
    }

    private var fanDetail: String {
        guard let fan = telemetry.fan else { return "Fanless or unavailable" }
        return "\(Int((fan.utilization * 100).rounded()))% · \(noiseTitle(fan.noiseEstimate))"
    }

    private var fanFootnote: String {
        guard let fan = telemetry.fan else { return "No microphone access" }
        return "\(fan.count) fan\(fan.count == 1 ? "" : "s") · RPM-based estimate"
    }

    private func noiseTitle(_ estimate: FanNoiseEstimate) -> String {
        switch estimate {
        case .stopped: "Stopped"
        case .nearlySilent: "Nearly silent"
        case .quiet: "Quiet"
        case .audible: "Audible"
        case .highAirflow: "High airflow"
        }
    }
}

private struct TelemetryMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let footnote: String
    let icon: String
    let tint: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HUDAccentIcon(symbol: icon, tint: tint, size: 27, symbolSize: 12, cornerRadius: 9)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(detail)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.11))
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 5)
                .transition(.opacity)
            } else {
                Capsule()
                    .fill(tint.opacity(0.34))
                    .frame(height: 5)
            }

            Text(footnote)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct HUDProgressRow: View {
    let title: String
    let value: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).lineLimit(1)
            }
            .font(.caption)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.12))
                    Capsule()
                        .fill(tint.opacity(0.94))
                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct SystemIdentityCard: View {
    let snapshot: SystemHUDSnapshot

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HUDSectionHeader(
                    title: "This Mac",
                    subtitle: "Identity and software",
                    icon: "desktopcomputer",
                    tint: HUDPalette.slate
                )
                IdentityRow(
                    icon: "person.crop.circle.fill",
                    title: snapshot.loggedInUser,
                    detail: "@\(snapshot.username)",
                    tint: HUDPalette.mauve
                )
                IdentityRow(
                    icon: "apple.logo",
                    title: snapshot.operatingSystem,
                    detail: snapshot.operatingSystemBuild.map { "Build \($0)" } ?? "Build unavailable",
                    tint: HUDPalette.slate
                )
                UpdateStatusRow(status: snapshot.softwareUpdateStatus)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct IdentityRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            HUDAccentIcon(symbol: icon, tint: tint, size: 28, symbolSize: 13, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct UpdateStatusRow: View {
    let status: SoftwareUpdateStatus

    var body: some View {
        IdentityRow(icon: icon, title: title, detail: detail, tint: tint)
            .animation(.easeOut(duration: 0.25), value: status)
    }

    private var icon: String {
        switch status {
        case .checking: "clock.arrow.circlepath"
        case .upToDate: "checkmark.seal.fill"
        case .available: "arrow.down.circle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    private var title: String {
        switch status {
        case .checking: "Checking updates"
        case .upToDate: "Software is up to date"
        case let .available(count, _): "\(count) update\(count == 1 ? "" : "s") available"
        case .unavailable: "Update status unavailable"
        }
    }

    private var detail: String {
        switch status {
        case .checking: "Reading the cached catalog"
        case .upToDate: "Cached macOS update catalog"
        case let .available(_, title): title ?? "Open System Settings to review"
        case .unavailable: "Open System Settings to check"
        }
    }

    private var tint: Color {
        switch status {
        case .upToDate: HUDPalette.sage
        case .available: HUDPalette.amber
        case .checking, .unavailable: HUDPalette.slate
        }
    }
}

private struct StorageInsightsCard: View {
    let snapshot: SystemHUDSnapshot

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HUDSectionHeader(
                    title: "Storage",
                    subtitle: "Startup disk capacity",
                    icon: "internaldrive.fill",
                    tint: HUDPalette.amber
                )
                HUDProgressRow(
                    title: "Used",
                    value: storageText,
                    progress: usedFraction,
                    tint: HUDPalette.amber
                )
                IdentityRow(
                    icon: "externaldrive.fill",
                    title: freeText,
                    detail: "Available capacity",
                    tint: HUDPalette.sage
                )
                IdentityRow(
                    icon: "lock.shield.fill",
                    title: "Aggregate capacity only",
                    detail: "No folders or file contents scanned",
                    tint: HUDPalette.slate
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var usedFraction: Double {
        guard let total = snapshot.diskTotal, let free = snapshot.diskFree, total > 0 else { return 0 }
        return min(1, Double(total - min(total, free)) / Double(total))
    }

    private var storageText: String {
        guard let total = snapshot.diskTotal, let free = snapshot.diskFree else { return "Sampling…" }
        return "\(byteText(total - min(total, free))) / \(byteText(total))"
    }

    private var freeText: String {
        snapshot.diskFree.map(byteText) ?? "Sampling…"
    }

    private func byteText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

private struct NetworkSection: View {
    let snapshot: SystemHUDSnapshot
    let received: String
    let transmitted: String

    var body: some View {
        HUDSectionSurface {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    HUDSectionHeader(
                        title: "Network",
                        subtitle: "Addresses and active routes",
                        icon: "network",
                        tint: HUDPalette.blue
                    )

                    HStack(spacing: 10) {
                        NetworkRateLegend(
                            title: "Down",
                            value: received,
                            icon: "arrow.down",
                            tint: HUDPalette.blue
                        )
                        NetworkRateLegend(
                            title: "Up",
                            value: transmitted,
                            icon: "arrow.up",
                            tint: HUDPalette.sage
                        )
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    HUDNetworkAddressCard(
                        title: "LAN",
                        icon: "house.fill",
                        tint: HUDPalette.sage,
                        primary: labeledAddress("IPv4", snapshot.lanIPv4),
                        secondary: labeledAddress("IPv6", snapshot.lanIPv6)
                    )

                    HUDNetworkAddressCard(
                        title: "VPN",
                        icon: snapshot.vpnInterface == nil ? "lock.slash" : "lock.shield.fill",
                        tint: snapshot.vpnInterface == nil ? HUDPalette.slate : HUDPalette.sage,
                        primary: snapshot.vpnInterface.map { "Connected  ·  \($0)" } ?? "Not connected",
                        secondary: snapshot.vpnAddress ?? "No tunnel address"
                    )

                    HUDNetworkAddressCard(
                        title: "Public",
                        icon: "globe.americas.fill",
                        tint: HUDPalette.blue,
                        primary: labeledAddress("IPv4", snapshot.publicIPv4),
                        secondary: labeledAddress("IPv6", snapshot.publicIPv6)
                    )
                }
            }
        }
    }

    private func labeledAddress(_ family: String, _ address: String?) -> String {
        "\(family)  \(address ?? "Unavailable")"
    }
}

private struct HUDNetworkAddressCard: View {
    let title: String
    let icon: String
    let tint: Color
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HUDAccentIcon(symbol: icon, tint: tint, size: 28, symbolSize: 13, cornerRadius: 9)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(primary)
                    .foregroundStyle(.primary)
                Text(secondary)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: secondary)
    }
}
