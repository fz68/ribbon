import Foundation
import Testing
@testable import RibbonCore

/// The non-empty lines of the file at `path`.
private func logLines(at path: String) throws -> [String] {
    let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

/// The file half of the log, tested against its own temp files so no test
/// touches the process-wide sink. One test still covers the `Log.path`
/// round-trip, without asserting on the shared file other suites log into.
struct LogTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func appendsWritesInOrder() throws {
        let path = TestTemp.path("log-sink-append.log")
        try? FileManager.default.removeItem(atPath: path)
        let sink = LogFileSink(path: path)

        sink.write(Data("first\n".utf8))
        #expect(FileManager.default.fileExists(atPath: path), "the first write creates the file")

        sink.write(Data("second\n".utf8))
        let lines = try logLines(at: path)
        #expect(lines == ["first", "second"],
                "two writes append in order (got \(lines))")
    }

    @Test func recreatesTheFileAfterDeletion() throws {
        let path = TestTemp.path("log-sink-recreate.log")
        try? FileManager.default.removeItem(atPath: path)
        let sink = LogFileSink(path: path)

        sink.write(Data("before\n".utf8))
        try #require(FileManager.default.fileExists(atPath: path), "the sink writes the file")
        // The user may delete the log while the app runs: the next write must
        // recreate it rather than write into the unlinked inode.
        try FileManager.default.removeItem(atPath: path)

        sink.write(Data("after\n".utf8))
        #expect(FileManager.default.fileExists(atPath: path),
                "the write recreates the file after deletion")
        let lines = try logLines(at: path)
        #expect(lines == ["after"], "the recreated file holds exactly the new line")
    }

    @Test func pathChangeRedirectsLaterWrites() throws {
        let oldPath = TestTemp.path("log-sink-old.log")
        let newPath = TestTemp.path("log-sink-new.log")
        try? FileManager.default.removeItem(atPath: oldPath)
        try? FileManager.default.removeItem(atPath: newPath)
        let sink = LogFileSink(path: oldPath)

        sink.write(Data("old\n".utf8))
        sink.path = newPath
        #expect(sink.path == newPath, "the sink reads back the path just assigned")

        sink.write(Data("new\n".utf8))
        let old = try logLines(at: oldPath)
        let new = try logLines(at: newPath)
        #expect(old == ["old"], "the old file keeps only its own write (got \(old))")
        #expect(new == ["new"], "the new file receives only the later write (got \(new))")
    }

    /// The process-wide path is asserted here, and nowhere else, because other
    /// suites write to it concurrently: this test never reads that file back.
    @Test func logPathRoundTrip() {
        let saved = Log.path
        defer { Log.path = saved }

        let path = TestTemp.path("log-roundtrip.log")
        Log.path = path
        #expect(Log.path == path, "Log.path reads back the value just assigned")
        log("roundtrip")
        #expect(FileManager.default.fileExists(atPath: path),
                "a write goes to the redirected path")
    }
}
