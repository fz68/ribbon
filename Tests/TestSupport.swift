import Foundation

/// Minimal, dependency-free test harness.
///
/// The repo has no SwiftPM and no XCTest bundle, so tests are plain Swift
/// compiled into a standalone executable. Assertions are silent when they
/// pass and print a `FAIL` line to stderr when they do not.
final class TestRunner {
    private(set) var checks: Int = 0
    private(set) var failures: Int = 0
    private var suite: String = ""

    /// Runs a named suite. The suite name is printed to stdout; failures
    /// raised inside the body are reported against this name.
    func run(_ name: String, _ body: (TestRunner) -> Void) {
        suite = name
        print("suite: \(name)")
        body(self)
    }

    func expect(_ condition: Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            report(message, file: file, line: line)
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            report(message, file: file, line: line)
        }
    }

    func expectNil<T>(_ value: T?, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if value != nil {
            failures += 1
            report(message, file: file, line: line)
        }
    }

    /// Prints the summary line and terminates the process. Exits 0 when every
    /// assertion passed, 1 otherwise.
    func finish() -> Never {
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    private func report(_ message: String, file: StaticString, line: UInt) {
        let text = "FAIL \(suite)/\(message) at \(file):\(line)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// The temporary directory every test writes into.
///
/// `TestMain` creates one directory per run, points the redirectable paths at
/// files inside it and deletes it when the run is over. Suites only ever build
/// paths with `path(_:)`, so no test can reach the user's real files.
enum TestTemp {
    /// Creates a fresh, unique directory inside the system temporary directory.
    static func makeRoot() -> String {
        let root = NSTemporaryDirectory() + "ribbon-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// The root of the current run. It is set once before the first suite.
    static var root: String = NSTemporaryDirectory()

    /// The path of `name` inside the current run's root.
    static func path(_ name: String) -> String {
        root + "/" + name
    }
}
