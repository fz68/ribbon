import Foundation
import Testing
@testable import RibbonCore

/// A thread safe holder for the flag the main queue completion delivers.
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ flag: Bool) {
        lock.lock()
        stored = flag
        lock.unlock()
    }
}

/// Writes an executable shell script at `path`, reporting whether it was written.
private func writeStub(_ body: String, to path: String) -> Bool {
    FileManager.default.createFile(atPath: path,
                                   contents: Data(("#!/bin/sh\n" + body).utf8),
                                   attributes: [.posixPermissions: 0o755])
}

@Suite(.serialized) final class ParsingTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testAeroSpaceWorkspaceEntries() {
        let basic = AeroSpace.workspaceEntries(Data("1|true\n2|false\n".utf8))
        #expect(basic.count == 2, "two lines produce two entries")
        if basic.count == 2 {
            #expect(basic[0].name == "1", "first entry keeps its name")
            #expect(basic[0].isFocused == true, "first entry is focused")
            #expect(basic[1].name == "2", "second entry keeps its name")
            #expect(basic[1].isFocused == false, "second entry is not focused")
        }

        let padded = AeroSpace.workspaceEntries(Data("  dev | TRUE \n".utf8))
        #expect(padded.count == 1, "a padded line still produces one entry")
        if padded.count == 1 {
            #expect(padded[0].name == "dev", "the name is trimmed")
            #expect(padded[0].isFocused == true, "the flag is trimmed and case-folded")
        }

        let broken = AeroSpace.workspaceEntries(Data("no separator\n1|true\n".utf8))
        #expect(broken.count == 1, "a line without | is skipped")
        if broken.count == 1 {
            #expect(broken[0].name == "1", "the well formed line survives")
        }

        let nameless = AeroSpace.workspaceEntries(Data("|true\n".utf8))
        #expect(nameless.count == 0, "an empty name is skipped")

        #expect(AeroSpace.workspaceEntries(Data()).count == 0, "empty input yields no entries")
        #expect(AeroSpace.workspaceEntries(Data([0xFF, 0xFE, 0x41])).count == 0,
                "non-UTF8 bytes yield no entries")
    }

    @Test func testAeroSpaceLines() {
        #expect(AeroSpace.lines(Data("a\nb\r\nc\n".utf8)) == ["a", "b", "c"],
                "LF and CRLF both split into lines")
        #expect(AeroSpace.lines(Data("a\n\n\nb\n".utf8)) == ["a", "b"],
                "blank lines are dropped")
        #expect(AeroSpace.lines(Data("  a  \n".utf8)) == ["a"],
                "each line is trimmed")
        #expect(AeroSpace.lines(Data()) == [], "empty input yields no lines")
        #expect(AeroSpace.lines(Data([0xFF, 0xFE, 0x41])) == [],
                "non-UTF8 bytes yield no lines")
    }

    @Test func testLogThrottledWritesOnce() {
        let saved = Log.path
        defer { Log.path = saved }

        // The throttle gate is process wide, so another test may have opened it.
        AeroSpace.resetLogThrottleForTesting()

        let path = TestTemp.path("log-throttled.log")
        try? FileManager.default.removeItem(atPath: path)
        Log.path = path

        AeroSpace.logThrottled("coverage-a")
        AeroSpace.logThrottled("coverage-b")

        let text = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
        let written = text.split(whereSeparator: \.isNewline)
        #expect(written.count == 1, "the second call is throttled (got \(written.count) lines)")
        #expect(text.contains("coverage-a"), "the first message is written")
        #expect(!text.contains("coverage-b"), "the throttled message is not written")
    }

    @Test func testWindowsByWorkspaceParsing() {
        let parsed = AeroSpace.windowsByWorkspace(
            from: Data("1|Safari\n1|Safari\n1|Mail\n1|Slack\n1|Xcode\nbadline\n|NoWS\n2|\n".utf8))
        #expect(parsed == ["1": ["Mail", "Safari", "Slack"]],
                "apps are deduped, sorted and capped at \(AeroSpace.maxAppsPerWorkspace)")
        #expect(parsed["2"] == nil, "a workspace with no app is dropped")
        #expect(AeroSpace.windowsByWorkspace(from: Data()) == [String: [String]](),
                "empty input yields no workspaces")
        #expect(AeroSpace.windowsByWorkspace(from: Data([0xFF, 0xFE, 0x41])) == [String: [String]](),
                "non-UTF8 bytes yield no workspaces")
    }

    @Test func testListBuildsWorkspaces() {
        let stub = TestTemp.path("aerospace-list-stub")
        try? FileManager.default.removeItem(atPath: stub)
        let body = """
        case "$1" in
        list-workspaces) printf '1|true\\n2|false\\n' ;;
        list-windows) printf '1|Safari\\n1|Mail\\n2|Slack\\n' ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the list stub was written")

        AeroSpace.binaryOverride = stub
        defer { AeroSpace.binaryOverride = nil }

        #expect(AeroSpace.list() == [Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"]),
                                     Workspace(name: "2", isFocused: false, apps: ["Slack"])],
                "the list joins workspace entries with their parsed apps")
    }

    @Test func testListFailsGracefully() {
        AeroSpace.binaryOverride = TestTemp.path("missing-aerospace")
        defer { AeroSpace.binaryOverride = nil }
        #expect(AeroSpace.list() == nil, "a missing binary yields no workspaces")

        let stub = TestTemp.path("aerospace-list-fail-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("exit 1\n", to: stub), "the failing stub was written")
        AeroSpace.binaryOverride = stub
        #expect(AeroSpace.list() == nil, "a failing list-workspaces yields no workspaces")
    }

    @Test func testFocusReportsCompletion() {
        let okStub = TestTemp.path("aerospace-focus-ok-stub")
        let failStub = TestTemp.path("aerospace-focus-fail-stub")
        try? FileManager.default.removeItem(atPath: okStub)
        try? FileManager.default.removeItem(atPath: failStub)
        #expect(writeStub("exit 0\n", to: okStub), "the succeeding stub was written")
        #expect(writeStub("exit 1\n", to: failStub), "the failing stub was written")

        AeroSpace.binaryOverride = okStub
        defer { AeroSpace.binaryOverride = nil }
        let okBox = CompletionBox()
        AeroSpace.focus("1") { okBox.store($0) }
        #expect(waitUntil { okBox.value != nil },
                "the completion runs within the wait window")
        #expect(okBox.value == true, "a zero exit reports success")

        AeroSpace.binaryOverride = failStub
        let failBox = CompletionBox()
        AeroSpace.focus("1") { failBox.store($0) }
        #expect(waitUntil { failBox.value != nil },
                "the completion runs within the wait window")
        #expect(failBox.value == false, "a non-zero exit reports failure")
    }

    @Test func testRunMapsStatuses() {
        let okStub = TestTemp.path("aerospace-run-ok-stub")
        let failStub = TestTemp.path("aerospace-run-fail-stub")
        try? FileManager.default.removeItem(atPath: okStub)
        try? FileManager.default.removeItem(atPath: failStub)
        #expect(writeStub("printf 'ok\\n'\n", to: okStub), "the succeeding stub was written")
        #expect(writeStub("exit 2\n", to: failStub), "the failing stub was written")

        #expect(AeroSpace.run(okStub, ["list-windows"]) == Data("ok\n".utf8),
                "a zero exit returns the captured stdout")
        #expect(AeroSpace.run(failStub, ["list-windows"]) == nil,
                "a non-zero exit returns nil")
        #expect(AeroSpace.run(TestTemp.path("missing-aerospace-run"), []) == nil,
                "an unlaunchable binary returns nil")
    }
}
