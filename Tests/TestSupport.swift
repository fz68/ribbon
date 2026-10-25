import Foundation
import Testing
@testable import RibbonCore

/// One-time bootstrap for the whole test run. The static initializer runs
/// exactly once per process, before the first test touches any path.
enum TestBootstrap {
    static let tempRoot: String = {
        let root = TestTemp.makeRoot()
        TestTemp.root = root
        Log.path = TestTemp.path("ribbon.log")
        InputSource.configurationPath = TestTemp.path("ime.json")
        TimeFormat.configurationPath = TestTemp.path("clock.json")
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
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}
