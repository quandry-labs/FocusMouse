import Foundation

@MainActor
protocol MouseTracking {
    var isRunning: Bool { get }
    @discardableResult
    func start() -> Bool
    func stop()
}
