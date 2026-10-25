import Foundation
import Testing
@testable import RibbonCore

/// A completed child run with `text` on stdout.
private func result(_ text: String) -> ProcessResult {
    ProcessResult(status: 0, stdout: Data(text.utf8), timedOut: false, launchError: nil)
}

@Suite(.serialized) final class VolumeTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testAdjustClampsRunnerOutput() {
        #expect(Volume.adjust(by: 0) { _, _, _ in result("42\n") } == 42,
                "the runner's value is returned")
        #expect(Volume.adjust(by: 0) { _, _, _ in result("100\n") } == 100,
                "100 is within range")
        #expect(Volume.adjust(by: 0) { _, _, _ in result("150\n") } == 100,
                "a value above 100 is clamped to 100")
        #expect(Volume.adjust(by: 0) { _, _, _ in result("-5\n") } == 0,
                "a negative value is clamped to 0")
        #expect(Volume.adjust(by: 0) { _, _, _ in result("  42  \n") } == 42,
                "surrounding whitespace is trimmed")
    }

    @Test func testAdjustHandlesRunnerFailure() {
        #expect(Volume.adjust(by: 0) { _, _, _ in nil } == nil,
                "a timeout (nil result) yields nil")
        #expect(Volume.adjust(by: 5) { _, _, _ in
            ProcessResult(status: 1, stdout: Data("42\n".utf8), timedOut: false, launchError: nil)
        } == nil, "a non-zero status yields nil")
        #expect(Volume.adjust(by: 5) { _, _, _ in
            ProcessResult(status: 0, stdout: Data("42\n".utf8), timedOut: true, launchError: nil)
        } == nil, "a timed out run yields nil")
        #expect(Volume.adjust(by: 5) { _, _, _ in result("abc\n") } == nil,
                "unparsable output yields nil")
    }

    @Test func testAdjustPassesTheDeltaToTheScript() {
        var captured: [String] = []
        _ = Volume.adjust(by: 7) { executable, arguments, timeout in
            captured = [executable, timeout.description] + arguments
            return result("50\n")
        }
        #expect(captured.first == "/usr/bin/osascript", "the script is run through osascript")
        #expect(captured.contains { $0.contains("+ (7)") },
                "the delta is part of the script")
        #expect(captured.contains { $0.contains("volume output volume") },
                "the script sets the output volume")
    }
}
