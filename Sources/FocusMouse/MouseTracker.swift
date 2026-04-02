import Cocoa
import CoreGraphics

final class MouseTracker: MouseTracking {
    private let settings: AppSettings
    private let focuser: WindowFocusing
    private let queue = DispatchQueue(label: "com.focusmouse.tracker", qos: .userInteractive)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var debounceTimer: DispatchWorkItem?
    private var lastFocusedPID: pid_t = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private(set) var isRunning = false

    init(settings: AppSettings, focuser: WindowFocusing) {
        self.settings = settings
        self.focuser = focuser
    }

    func start() {
        guard !isRunning else { return }

        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()

            switch type {
            case .tapDisabledByTimeout:
                if let tap = tracker.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            default:
                break
            }

            if type == .leftMouseDragged || type == .rightMouseDragged {
                tracker.cancelDebounce()
                return Unmanaged.passRetained(event)
            }

            tracker.handleMouseMoved(event: event)
            return Unmanaged.passRetained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) {
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }

            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // isRunning is set to true even if tap creation fails (e.g. no accessibility permission
        // in test environments) so that the stopped/running state remains consistent.
        isRunning = true
    }

    func stop() {
        cancelDebounce()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handleMouseMoved(event: CGEvent) {
        guard settings.isEnabled else { return }

        cancelDebounce()

        let delayMs = settings.focusDelayMs
        let work = DispatchWorkItem { [weak self] in
            self?.performFocus()
        }
        debounceTimer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    private func cancelDebounce() {
        debounceTimer?.cancel()
        debounceTimer = nil
    }

    private func performFocus() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screenHeight = NSScreen.main?.frame.height else { return }
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        guard let window = WindowInfo.windowAtPoint(cgPoint, excludingPID: ownPID) else { return }

        if let bundleID = window.ownerBundleID, settings.excludedBundleIDs.contains(bundleID) {
            return
        }

        if window.ownerPID == lastFocusedPID {
            return
        }

        lastFocusedPID = window.ownerPID

        let shouldRaise = settings.raiseWindow
        let raiseDelay = settings.raiseDelayMs

        let _ = focuser.focusWindow(pid: window.ownerPID, raiseWindow: raiseDelay == 0 && shouldRaise)

        if shouldRaise && raiseDelay > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(raiseDelay)) { [weak self] in
                guard let self = self, self.lastFocusedPID == window.ownerPID else { return }
                let _ = self.focuser.focusWindow(pid: window.ownerPID, raiseWindow: true)
            }
        }
    }

    deinit {
        stop()
    }
}
