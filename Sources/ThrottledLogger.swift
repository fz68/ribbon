import Foundation

/// A per-writer 60-second gate over the log, so one wedged tool cannot fill it.
final class ThrottledLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    /// Writes `message` at most once per minute.
    func emit(_ message: String) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(last) >= 60 else {
            lock.unlock()
            return
        }
        last = now
        lock.unlock()
        log(message)
    }

    /// Test hook: re-arms the gate, so the next call always writes.
    func resetForTesting() {
        lock.lock()
        last = Date.distantPast
        lock.unlock()
    }
}
