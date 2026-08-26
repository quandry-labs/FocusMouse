import Foundation
import Observation

enum SystemHUDPosition: String, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

enum SystemHUDAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AgentHUDLayout: String, CaseIterable, Identifiable {
    case adaptive
    case sideBySide
    case stacked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: "Adaptive"
        case .sideBySide: "Side by Side"
        case .stacked: "Stacked"
        }
    }
}

// MARK: - AppSettings

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    // MARK: Persisted properties

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }

    private var _focusDelayMs: Int
    var focusDelayMs: Int {
        get { _focusDelayMs }
        set {
            _focusDelayMs = max(0, min(1000, newValue))
            defaults.set(_focusDelayMs, forKey: "focusDelayMs")
        }
    }

    var raiseWindow: Bool {
        didSet { defaults.set(raiseWindow, forKey: "raiseWindow") }
    }

    private var _raiseDelayMs: Int
    var raiseDelayMs: Int {
        get { _raiseDelayMs }
        set {
            _raiseDelayMs = max(0, min(500, newValue))
            defaults.set(_raiseDelayMs, forKey: "raiseDelayMs")
        }
    }

    var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }

    var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: "showInDock") }
    }

    var isShortcutGuideEnabled: Bool {
        didSet { defaults.set(isShortcutGuideEnabled, forKey: "isShortcutGuideEnabled") }
    }

    var isSystemHUDEnabled: Bool {
        didSet { defaults.set(isSystemHUDEnabled, forKey: "isSystemHUDEnabled") }
    }

    private var _systemHUDOpacity: Double
    var systemHUDOpacity: Double {
        get { _systemHUDOpacity }
        set {
            _systemHUDOpacity = max(0.2, min(1.0, newValue))
            defaults.set(_systemHUDOpacity, forKey: "systemHUDOpacity")
        }
    }

    private var _systemHUDBackgroundBlur: Double
    var systemHUDBackgroundBlur: Double {
        get { _systemHUDBackgroundBlur }
        set {
            _systemHUDBackgroundBlur = max(0, min(1.0, newValue))
            defaults.set(_systemHUDBackgroundBlur, forKey: "systemHUDBackgroundBlur")
        }
    }

    var systemHUDAppearance: SystemHUDAppearance {
        didSet { defaults.set(systemHUDAppearance.rawValue, forKey: "systemHUDAppearance") }
    }

    private var _systemHUDRefreshInterval: Double
    var systemHUDRefreshInterval: Double {
        get { _systemHUDRefreshInterval }
        set {
            _systemHUDRefreshInterval = max(1.0, min(30.0, newValue))
            defaults.set(_systemHUDRefreshInterval, forKey: "systemHUDRefreshInterval")
        }
    }

    var systemHUDPosition: SystemHUDPosition {
        didSet { defaults.set(systemHUDPosition.rawValue, forKey: "systemHUDPosition") }
    }

    var systemHUDShowsNetwork: Bool {
        didSet { defaults.set(systemHUDShowsNetwork, forKey: "systemHUDShowsNetwork") }
    }

    var isAgentHUDEnabled: Bool {
        didSet { defaults.set(isAgentHUDEnabled, forKey: "isAgentHUDEnabled") }
    }

    var agentHUDLayout: AgentHUDLayout {
        didSet { defaults.set(agentHUDLayout.rawValue, forKey: "agentHUDLayout") }
    }

    private var _agentHUDRefreshInterval: Double
    var agentHUDRefreshInterval: Double {
        get { _agentHUDRefreshInterval }
        set {
            _agentHUDRefreshInterval = max(1.0, min(30.0, newValue))
            defaults.set(_agentHUDRefreshInterval, forKey: "agentHUDRefreshInterval")
        }
    }

    var agentHUDShowsTaskDetails: Bool {
        didSet { defaults.set(agentHUDShowsTaskDetails, forKey: "agentHUDShowsTaskDetails") }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            "isEnabled": true,
            "focusDelayMs": 200,
            "raiseWindow": true,
            "raiseDelayMs": 0,
            "showInDock": false,
            "isShortcutGuideEnabled": true,
            "isSystemHUDEnabled": false,
            "systemHUDOpacity": 0.82,
            "systemHUDBackgroundBlur": 0.78,
            "systemHUDAppearance": SystemHUDAppearance.system.rawValue,
            "systemHUDRefreshInterval": 2.0,
            "systemHUDPosition": SystemHUDPosition.topTrailing.rawValue,
            "systemHUDShowsNetwork": true,
            "isAgentHUDEnabled": false,
            "agentHUDLayout": AgentHUDLayout.adaptive.rawValue,
            "agentHUDRefreshInterval": 3.0,
            "agentHUDShowsTaskDetails": true,
        ])

        self.isEnabled = defaults.bool(forKey: "isEnabled")
        self._focusDelayMs = max(0, min(1000, defaults.integer(forKey: "focusDelayMs")))
        self.raiseWindow = defaults.bool(forKey: "raiseWindow")
        self._raiseDelayMs = max(0, min(500, defaults.integer(forKey: "raiseDelayMs")))
        self.excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        self.showInDock = defaults.bool(forKey: "showInDock")
        self.isShortcutGuideEnabled = defaults.bool(forKey: "isShortcutGuideEnabled")
        self.isSystemHUDEnabled = defaults.bool(forKey: "isSystemHUDEnabled")
        self._systemHUDOpacity = max(0.2, min(1.0, defaults.double(forKey: "systemHUDOpacity")))
        self._systemHUDBackgroundBlur = max(0, min(1.0, defaults.double(forKey: "systemHUDBackgroundBlur")))
        self.systemHUDAppearance = SystemHUDAppearance(
            rawValue: defaults.string(forKey: "systemHUDAppearance") ?? ""
        ) ?? .system
        self._systemHUDRefreshInterval = max(1.0, min(30.0, defaults.double(forKey: "systemHUDRefreshInterval")))
        self.systemHUDPosition = SystemHUDPosition(rawValue: defaults.string(forKey: "systemHUDPosition") ?? "") ?? .topTrailing
        self.systemHUDShowsNetwork = defaults.bool(forKey: "systemHUDShowsNetwork")
        self.isAgentHUDEnabled = defaults.bool(forKey: "isAgentHUDEnabled")
        self.agentHUDLayout = AgentHUDLayout(rawValue: defaults.string(forKey: "agentHUDLayout") ?? "") ?? .adaptive
        self._agentHUDRefreshInterval = max(1.0, min(30.0, defaults.double(forKey: "agentHUDRefreshInterval")))
        self.agentHUDShowsTaskDetails = defaults.bool(forKey: "agentHUDShowsTaskDetails")
    }
}
