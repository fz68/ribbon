import Foundation
import Testing
@testable import RibbonCore

/// Pins the one-line-per-minute gate that both backends write their errors
/// through. Each test owns a fresh logger, so the gate starts open.
@Suite(.serialized) final class ThrottledLoggerTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testTheFirstLineAlwaysWrites() {
        let logger = ThrottledLogger()
        logger.emit("throttled-logger-tests-first-line")
        let text = (try? String(contentsOfFile: Log.path, encoding: .utf8)) ?? ""
        #expect(text.contains("throttled-logger-tests-first-line"),
                "a fresh logger writes the first line straight through")
    }

    @Test func testTheSecondLineIsGatedWithinTheWindow() {
        let logger = ThrottledLogger()
        logger.emit("throttled-logger-tests-gate-a")
        logger.emit("throttled-logger-tests-gate-b")
        let text = (try? String(contentsOfFile: Log.path, encoding: .utf8)) ?? ""
        #expect(text.contains("throttled-logger-tests-gate-a"),
                "the first line landed")
        #expect(!text.contains("throttled-logger-tests-gate-b"),
                "the second line is gated inside the 60s window")
    }

    @Test func testResetForTestingRearmsTheGate() {
        let logger = ThrottledLogger()
        logger.emit("throttled-logger-tests-reset-a")
        logger.resetForTesting()
        logger.emit("throttled-logger-tests-reset-b")
        let text = (try? String(contentsOfFile: Log.path, encoding: .utf8)) ?? ""
        #expect(text.contains("throttled-logger-tests-reset-a")
                && text.contains("throttled-logger-tests-reset-b"),
                "the reset re-arms the gate so both lines land")
    }
}
