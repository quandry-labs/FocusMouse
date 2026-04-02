import Foundation

protocol MouseTracking {
    var isRunning: Bool { get }
    func start()
    func stop()
}
