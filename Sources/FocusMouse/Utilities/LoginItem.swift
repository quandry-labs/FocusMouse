import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.focusmouse", category: "LoginItem")

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            // SMAppService can fail if sandboxed or if the user denies.
            // Log and return failure — UI reflects actual state via isEnabled.
            logger.error("LoginItem.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
