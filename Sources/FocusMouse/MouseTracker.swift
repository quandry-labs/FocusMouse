import Cocoa
import CoreGraphics

@MainActor
final class MouseTracker: MouseTracking {
    typealias WindowLookup = @MainActor (CGPoint, pid_t) -> WindowInfo?

    /// Movement is observed passively. Button down/up events are deliberately
    /// absent so FocusMouse cannot react to, suppress, or transform clicks.
    static let observedEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged
    ]

    static var observedEventMask: CGEventMask {
        observedEventTypes.reduce(0) { mask, type in
            mask | (1 << type.rawValue)
        }
    }

    private let settings: AppSettings
    private let focuser: WindowFocusing
    private let windowLookup: WindowLookup
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelfPointer: UnsafeMutableRawPointer?
    private var focusTask: Task<Void, Never>?
    private var raiseTask: Task<Void, Never>?
    private var latestPointerLocation: CGPoint?

    private(set) var isRunning = false

    init(
        settings: AppSettings,
        focuser: WindowFocusing,
        windowLookup: @escaping WindowLookup = WindowInfo.windowAtPoint
    ) {
        self.settings = settings
        self.focuser = focuser
        self.windowLookup = windowLookup
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()

            MainActor.assumeIsolated {
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = tracker.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                default:
                    tracker.handlePointerEvent(type: type, location: event.location)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.observedEventMask,
            callback: callback,
            userInfo: selfPointer
        ) else {
            Unmanaged<MouseTracker>.fromOpaque(selfPointer).release()
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Unmanaged<MouseTracker>.fromOpaque(selfPointer).release()
            return false
        }

        eventTap = tap
        runLoopSource = source
        retainedSelfPointer = selfPointer
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        cancelScheduledWork()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        latestPointerLocation = nil
        isRunning = false

        if let selfPointer = retainedSelfPointer {
            retainedSelfPointer = nil
            Unmanaged<MouseTracker>.fromOpaque(selfPointer).release()
        }
    }

    func handlePointerEvent(type: CGEventType, location: CGPoint) {
        latestPointerLocation = location
        cancelScheduledWork()

        guard settings.isEnabled else { return }
        guard type == .mouseMoved else { return }

        // A one-frame minimum prevents 0 ms mode from enumerating all windows at raw mouse Hz.
        let effectiveDelayMs = max(16, settings.focusDelayMs)
        focusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(effectiveDelayMs))
            } catch {
                return
            }

            guard let self, self.latestPointerLocation == location else { return }
            self.focus(at: location)
            self.focusTask = nil
        }
    }

    private func focus(at point: CGPoint) {
        guard let window = eligibleWindow(at: point) else { return }

        let shouldRaise = settings.raiseWindow
        let raiseDelay = settings.raiseDelayMs
        let focused = focuser.focusWindow(
            window,
            at: point,
            raiseWindow: shouldRaise && raiseDelay == 0
        )
        guard focused, shouldRaise, raiseDelay > 0 else { return }

        raiseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(raiseDelay))
            } catch {
                return
            }

            guard let self,
                  self.settings.isEnabled,
                  self.latestPointerLocation == point,
                  let currentWindow = self.eligibleWindow(at: point),
                  currentWindow.windowID == window.windowID
            else {
                return
            }

            _ = self.focuser.focusWindow(currentWindow, at: point, raiseWindow: true)
            self.raiseTask = nil
        }
    }

    private func eligibleWindow(at point: CGPoint) -> WindowInfo? {
        guard let window = windowLookup(point, ownPID),
              let bundleID = window.ownerBundleID,
              !settings.excludedBundleIDs.contains(bundleID)
        else {
            return nil
        }
        return window
    }

    private func cancelScheduledWork() {
        focusTask?.cancel()
        focusTask = nil
        raiseTask?.cancel()
        raiseTask = nil
    }
}
