import Foundation

enum SessionState {
    case idle
    case running
    case terminated(Int32?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
