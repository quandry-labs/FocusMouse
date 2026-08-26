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
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            return .success(())
        } catch {
            logger.error("LoginItem.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
