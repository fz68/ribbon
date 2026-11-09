import Foundation
import Testing
@testable import RibbonCore

/// One-time bootstrap for the whole test run. The static initializer runs
/// exactly once per process, before the first test touches any path.
///
/// The redirects are process-global. A suite that uses `AgentConfig` (or any
/// other redirected path) must touch `TestBootstrap.tempRoot` in its `init` so
/// this bootstrap has run first.
enum TestBootstrap {
    static let tempRoot: String = {
        let root = TestTemp.makeRoot()
        TestTemp.root = root
        Log.path = TestTemp.path("ribbon.log")
        InputSource.configurationPath = TestTemp.path("ime.json")
        TimeFormat.configurationPath = TestTemp.path("clock.json")
        AgentConfig.configurationPath = TestTemp.path("agent.json")
        return root
    }()
}

/// The temporary directory every test writes into.
///
/// `TestBootstrap` creates one directory per run and points the redirectable
/// paths at files inside it before any suite runs. Suites only ever build
/// paths with `path(_:)`, so no test can reach the user's real files.
enum TestTemp {
    /// Creates a fresh, unique directory inside the system temporary directory.
    static func makeRoot() -> String {
        let root = NSTemporaryDirectory() + "ribbon-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// The root of the current run. It is set once, by `TestBootstrap`.
    static var root: String = NSTemporaryDirectory()

    /// The path of `name` inside the current run's root.
    static func path(_ name: String) -> String {
        root + "/" + name
    }
}

/// Polls `condition` until it is true or `timeout` passes. 20 ms interval.
///
/// Every caller waits for a completion callback that is delivered through
/// `DispatchQueue.main.async`, so the window covers the whole hop from spawning
/// the process to that delivery. Two seconds is too tight on a loaded CI runner;
/// the poll returns as soon as the condition holds, so a wide window costs
/// nothing on the fast path. The window is measured on the monotonic clock, so a
/// system sleep or a long main-thread stall cannot consume it.
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now() + timeout
    while DispatchTime.now() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

/// A lock-guarded holder for the one value a background delivery writes.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    init(_ value: Value? = nil) { stored = value }

    /// Records the delivered value.
    func store(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    /// The delivered value, or nil while nothing has arrived.
    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

extension Box where Value == Int {
    /// Adds one to the stored count, starting from zero when nothing was stored.
    func bump() {
        store((value ?? 0) + 1)
    }
}

/// Writes an executable `#!/bin/sh` script at `path`, replacing any earlier file.
@discardableResult
func writeStub(_ body: String, to path: String) -> Bool {
    try? FileManager.default.removeItem(atPath: path)
    return FileManager.default.createFile(atPath: path,
                                          contents: Data(("#!/bin/sh\n" + body).utf8),
                                          attributes: [.posixPermissions: 0o755])
}
