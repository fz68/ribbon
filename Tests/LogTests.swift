import Foundation
import Testing
@testable import RibbonCore

/// The non-empty lines of the log file, or an empty array when it is missing.
private func logLines(at path: String) -> [String] {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

@Suite(.serialized) final class LogTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testLog() {
        let path = TestTemp.path("log-tests.log")
        try? FileManager.default.removeItem(atPath: path)
        Log.path = path

        log("first")
        log("second")
        #expect(FileManager.default.fileExists(atPath: path), "the log file is created")

        let appended = logLines(at: path)
        #expect(appended.count == 2, "two writes append two lines (got \(appended.count))")
        #expect(appended.first?.contains("first") == true, "the first message is in the log")
        #expect(appended.last?.contains("second") == true, "the second message is in the log")

        // The user may delete the log while the app runs: the next write must
        // recreate it rather than write into the unlinked inode.
        try? FileManager.default.removeItem(atPath: path)
        log("third")
        #expect(FileManager.default.fileExists(atPath: path),
                "the log file is recreated after deletion")

        let recreated = logLines(at: path)
        #expect(recreated.count == 1, "the recreated log holds exactly one line")
        #expect(recreated.first?.contains("third") == true,
                "the recreated log holds the new message")
    }

    @Test func testLogPathRoundTrip() {
        let saved = Log.path
        defer { Log.path = saved }

        let path = TestTemp.path("log-roundtrip.log")
        try? FileManager.default.removeItem(atPath: path)
        Log.path = path

        #expect(Log.path == path, "Log.path reads back the value just assigned")
        log("roundtrip")
        #expect(FileManager.default.fileExists(atPath: path),
                "a write goes to the redirected path")
        #expect(logLines(at: path).count == 1,
                "the redirected file holds exactly the new line")
    }
}
