import Foundation
import Testing
@testable import RibbonCore

/// A thread-safe counter for the pokes the monitor delivers.
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

/// Writes an executable shell script at `path`, reporting whether it was written.
private func writeStub(_ body: String, to path: String) -> Bool {
    FileManager.default.createFile(atPath: path,
                                   contents: Data(("#!/bin/sh\n" + body).utf8),
                                   attributes: [.posixPermissions: 0o755])
}

@Suite(.serialized) final class WorkspaceMonitorTests {
    init() { _ = TestBootstrap.tempRoot }

    /// Builds a monitor over a fresh pair of queues, as the two backends do.
    private func makeMonitor(label: String,
                             arguments: [String],
                             validatesJSON: Bool,
                             hasIPC: Bool,
                             binary: @escaping () -> String?)
        -> WorkspaceMonitor {
        WorkspaceMonitor(label: label,
                         subscribeArguments: arguments,
                         validatesJSON: validatesJSON,
                         hasIPC: { hasIPC },
                         binary: binary,
                         queue: DispatchQueue(label: "ribbon.test.workspace-monitor"),
                         reapQueue: DispatchQueue.global(qos: .utility),
                         log: ThrottledLogger())
    }

    // MARK: - polling

    @Test func testPollingPathFiresTheChange() {
        let stub = TestTemp.path("monitor-poll-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("echo ok", to: stub), "the polling stub was written")
        let counter = CounterBox()
        let monitor = makeMonitor(label: "aerospace",
                                  arguments: ["subscribe"],
                                  validatesJSON: true,
                                  hasIPC: false,
                                  binary: { stub })
        monitor.start { counter.increment() }
        // The poll interval is 1.0 s, so one fire must land inside the window.
        #expect(waitUntil { counter.value >= 1 }, "the one-second poll pokes the change")
        monitor.stop()
        let frozen = counter.value
        _ = waitUntil(timeout: 0.1) { false }
        #expect(counter.value == frozen, "stop halts the poll, so the counter no longer grows")
    }

    // MARK: - subscribe

    @Test func testSubscribePathFiresOnAValidJSONLine() {
        let stub = TestTemp.path("monitor-subscribe-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub(#"printf '{"id":"1","ok":true}\n'"#, to: stub),
                "the subscribe stub was written")
        let counter = CounterBox()
        let monitor = makeMonitor(label: "aerospace",
                                  arguments: ["subscribe"],
                                  validatesJSON: true,
                                  hasIPC: true,
                                  binary: { stub })
        monitor.start { counter.increment() }
        // The stub prints one JSON line and exits; the poke is the line.
        #expect(waitUntil { counter.value >= 1 }, "a valid JSON line pokes the change")
        monitor.stop()
    }

    @Test func testValidatedModeIgnoresANonJSONLine() {
        let stub = TestTemp.path("monitor-nonjson-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("printf 'notajson\\n'", to: stub),
                "the non-JSON stub was written")
        let counter = CounterBox()
        let monitor = makeMonitor(label: "aerospace",
                                  arguments: ["subscribe"],
                                  validatesJSON: true,
                                  hasIPC: true,
                                  binary: { stub })
        monitor.start { counter.increment() }
        _ = waitUntil(timeout: 1.5) { counter.value >= 1 }
        #expect(counter.value == 0, "a non-JSON line does not poke in validated mode")
        monitor.stop()
    }

    @Test func testUnvalidatedModePokesOnAnyNonEmptyLine() {
        let stub = TestTemp.path("monitor-plain-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("printf 'notajson\\n'", to: stub),
                "the plain-line stub was written")
        let counter = CounterBox()
        let monitor = makeMonitor(label: "aerospace",
                                  arguments: ["subscribe"],
                                  validatesJSON: false,
                                  hasIPC: true,
                                  binary: { stub })
        monitor.start { counter.increment() }
        #expect(waitUntil { counter.value >= 1 },
                "without JSON validation any non-empty line pokes")
        monitor.stop()
    }

    // MARK: - restart

    @Test func testRestartBeginsAgainWithoutTheOldChild() {
        let stub = TestTemp.path("monitor-restart-stub")
        try? FileManager.default.removeItem(atPath: stub)
        #expect(writeStub("echo ok", to: stub), "the restart stub was written")
        let counter = CounterBox()
        let monitor = makeMonitor(label: "aerospace",
                                  arguments: ["subscribe"],
                                  validatesJSON: true,
                                  hasIPC: false,
                                  binary: { stub })
        monitor.start { counter.increment() }
        #expect(waitUntil { counter.value >= 1 }, "the first begin pokes")
        monitor.restart()
        // The restart re-arms the same timer, so pokes keep coming.
        #expect(waitUntil { counter.value >= 2 }, "restart keeps poking without the old child")
        monitor.stop()
    }
}
