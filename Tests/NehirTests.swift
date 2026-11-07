import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class NehirTests {
    init() { _ = TestBootstrap.tempRoot }

    // MARK: - workspaceEntries

    @Test func testNehirWorkspaceEntries() {
        // Display name used when non-empty; raw name as fallback; is-current maps.
        let basic = Nehir.workspaceEntries(Data(
            #"{"id":"1","kind":"query","ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"rawName":"1","displayName":"web","isCurrent":true},{"rawName":"2","isCurrent":false}]}},"status":"success"}"#
                .utf8))
        #expect(basic.count == 2, "two items produce two entries")
        if basic.count == 2 {
            #expect(basic[0].name == "web", "display name used when non-empty")
            #expect(basic[0].rawName == "1", "raw name stored")
            #expect(basic[0].isFocused == true, "is-current true is focused")
            #expect(basic[1].name == "2", "absent display name falls back to raw name")
            #expect(basic[1].isFocused == false, "is-current false is not focused")
        }

        // An ok:false envelope yields no entries.
        let failed = Nehir.workspaceEntries(Data(
            #"{"id":"2","kind":"query","ok":false,"result":null,"status":"failure"}"#.utf8))
        #expect(failed.count == 0, "an ok false envelope yields no entries")

        // An item with no rawName is skipped.
        let nameless = Nehir.workspaceEntries(Data(
            #"{"ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"displayName":"x","isCurrent":true}]}}}"#
                .utf8))
        #expect(nameless.count == 0, "item without a raw name is skipped")

        // An empty workspaces array yields no entries.
        let empty = Nehir.workspaceEntries(Data(
            #"{"ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[]}}}"#.utf8))
        #expect(empty.count == 0, "empty workspaces array yields no entries")

        // Invalid or missing JSON.
        #expect(Nehir.workspaceEntries(Data()).count == 0, "empty input yields no entries")
        #expect(Nehir.workspaceEntries(Data([0xFF, 0xFE, 0x41])).count == 0,
                "invalid bytes yield no entries")
    }

    // MARK: - windowsByWorkspace(from:)

    @Test func testNehirWindowsByWorkspace() {
        // Workspace "1": Safari twice (deduped), Mail, Slack, Xcode -> capped at 3.
        // Workspace "2": Finder plus a row without an app key (skipped).
        // Last row: no workspace raw name (skipped).
        let json = #"{"ok":true,"kind":"query","result":{"kind":"windows","payload":{"windows":[{"app":{"name":"Safari","bundleId":"x"},"workspace":{"rawName":"1","displayName":"web"}},{"app":{"name":"Safari"},"workspace":{"rawName":"1"}},{"app":{"name":"Mail"},"workspace":{"rawName":"1"}},{"app":{"name":"Slack"},"workspace":{"rawName":"1"}},{"app":{"name":"Xcode"},"workspace":{"rawName":"1"}},{"app":{"name":"Finder"},"workspace":{"rawName":"2"}},{"workspace":{"rawName":"2"}},{"app":{"name":"Notes"},"workspace":{"displayName":"web"}}]}}}"#
        let parsed = Nehir.windowsByWorkspace(from: Data(json.utf8))
        #expect(parsed["1"] == ["Mail", "Safari", "Slack"],
                "apps deduped, sorted, capped at \(Nehir.maxAppsPerWorkspace)")
        #expect(parsed["2"] == ["Finder"], "second workspace parsed, app-less row skipped")
        #expect(parsed.count == 2, "row without a workspace raw name is skipped")

        #expect(Nehir.windowsByWorkspace(from: Data()) == [String: [String]](),
                "empty input yields no workspaces")
        #expect(Nehir.windowsByWorkspace(from: Data([0xFF, 0xFE, 0x41])) == [String: [String]](),
                "invalid bytes yield no workspaces")
    }

    // MARK: - list()

    @Test func testNehirListBuildsWorkspaces() {
        let stub = TestTemp.path("nehir-list-stub")
        try? FileManager.default.removeItem(atPath: stub)
        let body = """
        case "$2" in
        workspaces) printf '{"id":"1","kind":"query","ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"rawName":"1","displayName":"Browsing","isCurrent":true},{"rawName":"2","isCurrent":false}]}},"status":"success"}\\n' ;;
        windows) printf '{"id":"2","kind":"query","ok":true,"result":{"kind":"windows","payload":{"windows":[{"app":{"name":"Safari","bundleId":"x"},"workspace":{"rawName":"1","displayName":"Browsing"}},{"app":{"name":"Mail"},"workspace":{"rawName":"1"}},{"app":{"name":"Slack"},"workspace":{"rawName":"2"}}]}},"status":"success"}\\n' ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the list stub was written")

        Nehir.binaryOverride = stub
        defer { Nehir.binaryOverride = nil }

        #expect(Nehir.list() == [
            Workspace(name: "Browsing", isFocused: true, apps: ["Mail", "Safari"]),
            Workspace(name: "2", isFocused: false, apps: ["Slack"]),
        ], "the list joins workspace entries with their parsed apps")
    }

    @Test func testNehirListToleratesDuplicateDisplayNames() {
        let stub = TestTemp.path("nehir-dup-stub")
        let argsFile = TestTemp.path("nehir-dup-focus-args")
        try? FileManager.default.removeItem(atPath: stub)
        try? FileManager.default.removeItem(atPath: argsFile)
        let body = """
        case "$2" in
        workspaces) printf '{"id":"1","kind":"query","ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"rawName":"1","displayName":"Main","isCurrent":true},{"rawName":"2","displayName":"Main","isCurrent":false}]}},"status":"success"}\\n' ;;
        windows) printf '{"id":"2","kind":"query","ok":true,"result":{"kind":"windows","payload":{"windows":[]}},"status":"success"}\\n' ;;
        focus-name) printf '%s\\n' "$*" >> \(argsFile); exit 1 ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the duplicate-name stub was written")

        Nehir.binaryOverride = stub
        defer { Nehir.binaryOverride = nil }

        // Two workspaces share the display name "Main"; the list must not trap.
        let workspaces = Nehir.list()
        #expect(workspaces?.count == 2, "two entries are returned")
        if let workspaces, workspaces.count == 2 {
            #expect(workspaces[0].name == "Main" && workspaces[0].isFocused,
                    "first entry is named Main and focused")
            #expect(workspaces[1].name == "Main" && !workspaces[1].isFocused,
                    "second entry shares the name Main")
        }

        // The ambiguous label passes through unrewritten and Nehir rejects it,
        // so the completion reports failure.
        let box = Box<Bool>()
        Nehir.focus("Main") { box.store($0) }
        #expect(waitUntil { box.value != nil },
                "the completion runs within the wait window")
        #expect(box.value == false, "the ambiguous focus is rejected")

        let written = (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? ""
        #expect(written.contains("workspace focus-name Main"),
                "the ambiguous label passed through as the display name")
        #expect(!written.contains("workspace focus-name 2"),
                "the ambiguous label was not rewritten to a raw ID")
    }

    @Test func testNehirListFailsGracefully() {
        Nehir.binaryOverride = TestTemp.path("missing-nehir")
        defer { Nehir.binaryOverride = nil }
        #expect(Nehir.list() == nil, "a missing binary yields no workspaces")

        let stub = TestTemp.path("nehir-list-fail-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("exit 1\n", to: stub), "the failing stub was written")
        Nehir.binaryOverride = stub
        #expect(Nehir.list() == nil, "a failing query yields no workspaces")

        let okFalseStub = TestTemp.path("nehir-list-okfalse-stub")
        try? FileManager.default.removeItem(atPath: okFalseStub)
        #expect(writeStub(
            #"printf '{"id":"1","kind":"query","ok":false,"result":null,"status":"failure"}\n'"# + "\n",
            to: okFalseStub), "the ok false stub was written")
        Nehir.binaryOverride = okFalseStub
        #expect(Nehir.list() == nil, "an ok false envelope yields no workspaces")
    }

    // MARK: - focus()

    @Test func testNehirFocusReportsCompletion() {
        let okStub = TestTemp.path("nehir-focus-ok-stub")
        let failStub = TestTemp.path("nehir-focus-fail-stub")
        try? FileManager.default.removeItem(atPath: okStub)
        try? FileManager.default.removeItem(atPath: failStub)
        #expect(writeStub("exit 0\n", to: okStub), "the succeeding stub was written")
        #expect(writeStub("exit 1\n", to: failStub), "the failing stub was written")

        Nehir.binaryOverride = okStub
        defer { Nehir.binaryOverride = nil }
        let okBox = Box<Bool>()
        Nehir.focus("1") { okBox.store($0) }
        #expect(waitUntil { okBox.value != nil },
                "the completion runs within the wait window")
        #expect(okBox.value == true, "a zero exit reports success")

        Nehir.binaryOverride = failStub
        let failBox = Box<Bool>()
        Nehir.focus("1") { failBox.store($0) }
        #expect(waitUntil { failBox.value != nil },
                "the completion runs within the wait window")
        #expect(failBox.value == false, "a non-zero exit reports failure")
    }

    @Test func testNehirFocusResolvesDisplayNamesToRawIDs() {
        let stub = TestTemp.path("nehir-focus-map-stub")
        let argsFile = TestTemp.path("nehir-focus-args")
        try? FileManager.default.removeItem(atPath: stub)
        try? FileManager.default.removeItem(atPath: argsFile)
        let body = """
        case "$2" in
        workspaces) printf '{"id":"1","kind":"query","ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"rawName":"1","displayName":"Browsing","isCurrent":true},{"rawName":"2","isCurrent":false}]}},"status":"success"}\\n' ;;
        windows) printf '{"id":"2","kind":"query","ok":true,"result":{"kind":"windows","payload":{"windows":[{"app":{"name":"Safari","bundleId":"x"},"workspace":{"rawName":"1","displayName":"Browsing"}},{"app":{"name":"Mail"},"workspace":{"rawName":"1"}},{"app":{"name":"Slack"},"workspace":{"rawName":"2"}}]}},"status":"success"}\\n' ;;
        focus-name) printf '%s\\n' "$*" >> \(argsFile) ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the focus-map stub was written")

        Nehir.binaryOverride = stub
        defer { Nehir.binaryOverride = nil }

        // A successful list() populates the display-name to raw-ID map.
        #expect(Nehir.list() != nil, "list populates the focus map")

        let box = Box<Bool>()
        Nehir.focus("Browsing") { box.store($0) }
        #expect(waitUntil { box.value != nil },
                "the completion runs within the wait window")
        #expect(box.value == true, "focus reports success")

        let written = (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? ""
        #expect(written.contains("workspace focus-name 1"),
                "the display name was resolved to the raw workspace ID")
    }

    // MARK: - WorkspaceBackendFactory

    @Test func testBackendFactorySelection() {
        let savedAS = WorkspaceBackendFactory.aerospaceAvailable
        let savedNH = WorkspaceBackendFactory.nehirAvailable
        defer {
            WorkspaceBackendFactory.aerospaceAvailable = savedAS
            WorkspaceBackendFactory.nehirAvailable = savedNH
        }

        WorkspaceBackendFactory.aerospaceAvailable = { true }
        WorkspaceBackendFactory.nehirAvailable = { true }
        #expect(WorkspaceBackendFactory.make() is AeroSpaceBackend,
                "when both are available AeroSpace wins")

        WorkspaceBackendFactory.aerospaceAvailable = { false }
        WorkspaceBackendFactory.nehirAvailable = { true }
        #expect(WorkspaceBackendFactory.make() is NehirBackend,
                "when only Nehir is available it is chosen")

        WorkspaceBackendFactory.aerospaceAvailable = { false }
        WorkspaceBackendFactory.nehirAvailable = { false }
        #expect(WorkspaceBackendFactory.make() is AeroSpaceBackend,
                "when neither is available AeroSpace is the fallback")
    }

    @Test func testAerospaceLivenessProbe() {
        let okStub = TestTemp.path("aerospace-live-ok")
        let failStub = TestTemp.path("aerospace-live-fail")
        try? FileManager.default.removeItem(atPath: okStub)
        try? FileManager.default.removeItem(atPath: failStub)
        #expect(writeStub("exit 0\n", to: okStub), "the exit-zero stub was written")
        #expect(writeStub("exit 1\n", to: failStub), "the exit-one stub was written")

        let saved = AeroSpace.binaryOverride
        defer { AeroSpace.binaryOverride = saved }

        AeroSpace.binaryOverride = okStub
        #expect(WorkspaceBackendFactory.aerospaceDaemonResponds(),
                "an exit-zero daemon counts as live")

        AeroSpace.binaryOverride = failStub
        #expect(WorkspaceBackendFactory.aerospaceDaemonResponds() == false,
                "a non-zero exit is not live")

        AeroSpace.binaryOverride = TestTemp.path("missing-aerospace")
        #expect(WorkspaceBackendFactory.aerospaceDaemonResponds() == false,
                "a missing binary is not live")
    }
}
