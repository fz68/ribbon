import Foundation
import Testing
@testable import RibbonCore

/// Pins the one-line-per-minute gate that both backends write their errors
/// through. Each test owns a fresh logger and records what passes the gate.
struct ThrottledLoggerTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func theFirstLineAlwaysWrites() {
        var lines: [String] = []
        let logger = ThrottledLogger { lines.append($0) }

        logger.emit("first-line")
        #expect(lines == ["first-line"], "a fresh logger writes the first line straight through")
    }

    @Test func theSecondLineIsGatedWithinTheWindow() {
        var lines: [String] = []
        let logger = ThrottledLogger { lines.append($0) }

        logger.emit("gate-a")
        logger.emit("gate-b")
        #expect(lines == ["gate-a"],
                "the second line is gated inside the 60s window (got \(lines))")
    }

    @Test func resetForTestingRearmsTheGate() {
        var lines: [String] = []
        let logger = ThrottledLogger { lines.append($0) }

        logger.emit("reset-a")
        logger.resetForTesting()
        logger.emit("reset-b")
        #expect(lines == ["reset-a", "reset-b"],
                "the reset re-arms the gate so both lines land (got \(lines))")
    }

    /// The production caller passes no recorder, so the line must reach the
    /// real `log()`. The process-global path is shared with other suites, which
    /// may append foreign lines while this test runs, so only the unique token
    /// is asserted - never a line count or the exact contents.
    @Test func theDefaultWriterReachesTheRealLog() throws {
        let saved = Log.path
        defer { Log.path = saved }

        let token = "throttled-default-probe"
        let path = TestTemp.path("throttled-default-\(UUID().uuidString).log")
        try? FileManager.default.removeItem(atPath: path)
        Log.path = path

        ThrottledLogger().emit(token)

        try #require(FileManager.default.fileExists(atPath: path),
                     "the default writer creates the redirected log file")
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(text.contains(token),
                "a no-argument ThrottledLogger routes through log() instead of swallowing the line")
    }
}
