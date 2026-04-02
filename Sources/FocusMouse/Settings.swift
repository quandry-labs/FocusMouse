import Foundation
import Observation

// MARK: - AppSettings

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

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: "showInDock") }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            "isEnabled": true,
            "focusDelayMs": 200,
            "raiseWindow": true,
            "raiseDelayMs": 0,
            "launchAtLogin": true,
            "showInDock": false,
        ])

        self.isEnabled = defaults.bool(forKey: "isEnabled")
        self._focusDelayMs = max(0, min(1000, defaults.integer(forKey: "focusDelayMs")))
        self.raiseWindow = defaults.bool(forKey: "raiseWindow")
        self._raiseDelayMs = max(0, min(500, defaults.integer(forKey: "raiseDelayMs")))
        self.excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.showInDock = defaults.bool(forKey: "showInDock")
    }
}
