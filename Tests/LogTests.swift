import Foundation

/// The non-empty lines of the log file, or an empty array when it is missing.
private func logLines(at path: String) -> [String] {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

internal func runLogTests(_ t: TestRunner) {
    t.run("Log") { t in
        let path = TestTemp.path("log-tests.log")
        try? FileManager.default.removeItem(atPath: path)
        Log.path = path

        log("first")
        log("second")
        t.expect(FileManager.default.fileExists(atPath: path), "the log file is created")

        let appended = logLines(at: path)
        t.expectEqual(appended.count, 2, "two writes append two lines (got \(appended.count))")
        t.expect(appended.first?.contains("first") == true, "the first message is in the log")
        t.expect(appended.last?.contains("second") == true, "the second message is in the log")

        // The user may delete the log while the app runs: the next write must
        // recreate it rather than write into the unlinked inode.
        try? FileManager.default.removeItem(atPath: path)
        log("third")
        t.expect(FileManager.default.fileExists(atPath: path),
                 "the log file is recreated after deletion")

        let recreated = logLines(at: path)
        t.expectEqual(recreated.count, 1, "the recreated log holds exactly one line")
        t.expect(recreated.first?.contains("third") == true,
                 "the recreated log holds the new message")
    }
}
