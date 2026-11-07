import Foundation
import Testing
@testable import RibbonCore

/// Thread safe holder for the values the main queue delivers.
private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
    func store(_ flag: Bool) { lock.lock(); stored = flag ? 1 : 0; lock.unlock() }
    func bump() { lock.lock(); stored = (stored ?? 0) + 1; lock.unlock() }
}

/// Writes an executable shell script at `path`, reporting whether it was written.
private func writeStub(_ body: String, to path: String) -> Bool {
    FileManager.default.createFile(atPath: path,
                                   contents: Data(("#!/bin/sh\n" + body).utf8),
                                   attributes: [.posixPermissions: 0o755])
}

/// The two `WorkspaceBackend` adapters are pass-throughs; these tests pin the
/// forwarding and the call safety of the monitoring triple.
@Suite(.serialized) final class WorkspaceBackendTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testAerospaceAdapterForwardsList() {
        let stub = TestTemp.path("wb-aerospace-list-stub")
        try? FileManager.default.removeItem(atPath: stub)
        let body = """
        case "$1" in
        list-workspaces) printf '1|true\n2|false\n' ;;
        list-windows) printf '1|Safari\n1|Mail\n2|Slack\n' ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the list stub was written")

        AeroSpace.binaryOverride = stub
        defer { AeroSpace.binaryOverride = nil }

        let viaBackend = AeroSpaceBackend().list()
        #expect(viaBackend != nil, "the adapter yields workspaces")
        #expect(viaBackend == AeroSpace.list(), "the adapter forwards to AeroSpace.list")
        #expect(viaBackend?.map { $0.name } == ["1", "2"], "the names match the stub")
    }

    @Test func testNehirAdapterForwardsList() {
        let stub = TestTemp.path("wb-nehir-list-stub")
        try? FileManager.default.removeItem(atPath: stub)
        let body = """
        case "$2" in
        workspaces) printf '{"id":"1","kind":"query","ok":true,"result":{"kind":"workspaces","payload":{"workspaces":[{"rawName":"1","displayName":"Browsing","isCurrent":true},{"rawName":"2","isCurrent":false}]}},"status":"success"}\\n' ;;
        windows) printf '{"id":"2","kind":"query","ok":true,"result":{"kind":"windows","payload":{"windows":[{"app":{"name":"Safari"},"workspace":{"rawName":"1"}},{"app":{"name":"Slack"},"workspace":{"rawName":"2"}}]}},"status":"success"}\\n' ;;
        esac
        """
        #expect(writeStub(body, to: stub), "the list stub was written")

        Nehir.binaryOverride = stub
        defer { Nehir.binaryOverride = nil }

        let viaBackend = NehirBackend().list()
        #expect(viaBackend != nil, "the adapter yields workspaces")
        #expect(viaBackend == Nehir.list(), "the adapter forwards to Nehir.list")
        #expect(viaBackend?.map { $0.name } == ["Browsing", "2"], "the names match the stub")
    }

    @Test func testAdapterFocusReportsThroughTheCompletion() {
        let okStub = TestTemp.path("wb-focus-ok-stub")
        let failStub = TestTemp.path("wb-focus-fail-stub")
        try? FileManager.default.removeItem(atPath: okStub)
        try? FileManager.default.removeItem(atPath: failStub)
        #expect(writeStub("exit 0\n", to: okStub), "the exit-zero stub was written")
        #expect(writeStub("exit 1\n", to: failStub), "the exit-one stub was written")

        AeroSpace.binaryOverride = okStub
        defer { AeroSpace.binaryOverride = nil }
        let okBox = IntBox()
        AeroSpaceBackend().focus("1") { okBox.store($0) }
        #expect(waitUntil { okBox.value != nil },
                "the completion runs within the wait window")
        #expect(okBox.value == 1, "a zero exit reports success")

        AeroSpace.binaryOverride = failStub
        let failBox = IntBox()
        AeroSpaceBackend().focus("1") { failBox.store($0) }
        #expect(waitUntil { failBox.value != nil },
                "the completion runs within the wait window")
        #expect(failBox.value == 0, "a non-zero exit reports failure")
    }

    @Test func testMonitoringCallsAreSafeWithoutAStream() {
        let stub = TestTemp.path("wb-monitor-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("printf '{\"type\":\"wb\"}\\n'\n", to: stub),
                "the subscribe stub was written")
        AeroSpace.binaryOverride = stub
        Nehir.binaryOverride = stub
        defer {
            AeroSpace.binaryOverride = nil
            Nehir.binaryOverride = nil
        }

        let aeroBox = IntBox()
        let aero = AeroSpaceBackend()
        aero.startMonitoring { aeroBox.bump() }
        aero.restartMonitoring()
        #expect(waitUntil { (aeroBox.value ?? 0) >= 1 },
                "the aerospace change counter reaches one")
        aero.stopMonitoring()
        aero.stopMonitoring()
        #expect((aeroBox.value ?? 0) >= 1, "the doubled aerospace stop is harmless")

        let nehirBox = IntBox()
        let nehir = NehirBackend()
        nehir.startMonitoring { nehirBox.bump() }
        nehir.restartMonitoring()
        #expect(waitUntil { (nehirBox.value ?? 0) >= 1 },
                "the nehir change counter reaches one")
        nehir.stopMonitoring()
        nehir.stopMonitoring()
        #expect((nehirBox.value ?? 0) >= 1, "the doubled nehir stop is harmless")
    }

    @Test func testBothPrioritiesAreIndependentEntries() {
        let appLabel = Theme.Layout.appLabelTrailingPriority
        let chipContent = Theme.Layout.chipContentTrailingPriority
        #expect(appLabel == 999, "the app label trailing priority is 999")
        #expect(chipContent == 999, "the chip content trailing priority is 999")
        #expect(appLabel == chipContent && appLabel != 0,
                "two separate declarations pin the same non-zero value")
    }
}
