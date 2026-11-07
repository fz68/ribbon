import Foundation
import Testing
@testable import RibbonCore

// MARK: - Stub support

/// Thread-safe holder for values the bridge queue writes.
private final class ABBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func withLock(_ body: (inout T) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

private struct ABReply {
    var status = 200
    var chunks: [Data] = []
}

/// One recorded request: path, method and body.
private struct ABRecorded {
    let path: String
    let method: String?
    let body: Data?
}

/// Replays scripted answers for the bridge, like the stream-stub does.
private final class ABStub: URLProtocol {
    private static let backend = ABBackend()

    static func install(_ handler: @escaping (URLRequest) -> ABReply) { backend.install(handler) }
    static func uninstall() { backend.uninstall() }
    static func recorded(path: String) -> [ABRecorded] {
        backend.records.filter { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = ABStub.backend.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: reply.status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ABBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) -> ABReply)?
    private var stored: [ABRecorded] = []

    func install(_ handler: @escaping (URLRequest) -> ABReply) {
        lock.lock()
        self.handler = handler
        stored = []
        lock.unlock()
    }

    func uninstall() {
        lock.lock()
        handler = nil
        stored = []
        lock.unlock()
    }

    var records: [ABRecorded] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ request: URLRequest) -> ABReply? {
        // URLSession hands the body over as a stream, so read it before storing.
        let body = request.httpBody ?? Self.readBody(request.httpBodyStream)
        lock.lock()
        let handler = self.handler
        stored.append(ABRecorded(path: request.url?.path ?? "",
                                method: request.httpMethod,
                                body: body))
        lock.unlock()
        return handler?(request)
    }

    private static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Fixed inputs

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private func json(_ text: String) -> ABReply { ABReply(chunks: [Data(text.utf8)]) }

private func abSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ABStub.self]
    return URLSession(configuration: configuration)
}

private func writeService(_ name: String, _ text: String) {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: TestTemp.path(name)))
}

private func makeBridge(name: String, session: URLSession) -> AgentBridge {
    AgentBridge(locator: ServiceLocator(path: TestTemp.path(name)),
                stream: EventStream(session: session,
                                    idleTimeout: 5,
                                    retryPolicy: StreamRetryPolicy(initialDelay: 0.05,
                                                                  maximumDelay: 0.5)),
                session: session,
                now: { fixedNow })
}

private let serviceJSON =
    #"{"url":"http://127.0.0.1:49374","password":"pw","version":"2.2.6","pid":1}"#
private let listJSON =
    #"[{"id":"ses_a","title":"A","location":{"directory":"/x/a"}},{"id":"ses_b","title":"B","location":{"directory":"/x/b"}}]"#
private let earlyForm =
    #"{"id":"evt_e","created":1700000001000,"type":"form.created","location":{"directory":"/x/b"},"data":{"form":{"id":"frm_early","sessionID":"ses_b","title":"Early","fields":[{"key":"k","title":"Early","type":"string","options":[{"value":"x","label":"X"},{"value":"y","label":"Y"}]}]}}}"#
private let lateForm =
    #"{"id":"evt_l","created":1700000003000,"type":"form.created","location":{"directory":"/x/a"},"data":{"form":{"id":"frm_late","sessionID":"ses_a","title":"Late","fields":[{"key":"k","title":"Late","type":"string","options":[{"value":"x","label":"X"},{"value":"y","label":"Y"}]}]}}}"#

// MARK: - Tests

@Suite(.serialized) final class AgentBridgeTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testNoServiceMeansNoChip() {
        writeService("agent-bridge-none.json", "42")
        let box = ABBox<[AgentSnapshot]>([])
        let bridge = makeBridge(name: "agent-bridge-none.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) { !box.value.isEmpty },
                "a read of the missing registration publishes once")
        #expect(box.value.allSatisfy { $0.visible == false },
                "no endpoint and no contact keep the chip hidden")
        #expect(box.value.contains { $0.chip == .idle },
                "an empty store publishes the idle chip")
        bridge.stop()
    }

    @Test func testSnapshotCarriesTheStoredCounts() {
        writeService("agent-bridge-service.json", serviceJSON)
        ABStub.install { request in
            switch request.url?.path ?? "" {
            case "/api/event":
                return json(": heartbeat\n\ndata: \(earlyForm)\n\ndata: \(lateForm)\n\n")
            case "/api/session/active":
                return json(#"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"idle"}}}"#)
            case "/api/session": return json(listJSON)
            case "/api/session/ses_a/permission":
                return json(#"{"data":[{"id":"per_a2","action":"edit","resources":[]},{"id":"per_a1","action":"bash","resources":["ls"]}]}"#)
            case "/api/session/ses_b/permission":
                return json(#"{"data":[{"id":"per_b1","action":"read","resources":[]}]}"#)
            default: return ABReply()
            }
        }
        defer { ABStub.uninstall() }
        let box = ABBox<[AgentSnapshot]>([])
        let bridge = makeBridge(name: "agent-bridge-service.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) {
            box.value.last.map { $0.triage.count == 3 && $0.formTriage.isEmpty } ?? false
        }, "the reconciled pending set reaches the published snapshot")
        let snapshot = box.value.last
        #expect(snapshot?.visible == true, "recent contact keeps the chip visible")
        #expect(snapshot?.chip == .awaiting(count: 2), "both sessions await, one group each")
        #expect(snapshot?.triage.map(\.requestID) == ["per_a1", "per_a2", "per_b1"],
                "permissions are oldest first; a time tie goes to the lower session id, then the lower request id")
        #expect(snapshot?.triage.map(\.position) == [1, 2, 3]
                    && snapshot?.triage.map(\.total) == [3, 3, 3],
                "positions are 1-based over the permission queue")
        #expect(snapshot?.triage.map(\.shortName) == ["a", "a", "b"],
                "the listed directory gives each target its short name")
        #expect(snapshot?.formTriage.isEmpty == true,
                "fetched pendings are permissions, so the authoritative replace leaves the form queue empty")
        bridge.stop()
    }

    @Test func testReplyReportsSuccessThenFailure() throws {
        writeService("agent-bridge-service.json", serviceJSON)
        let stage = ABBox(200)
        ABStub.install { request in
            switch request.url?.path ?? "" {
            case "/api/event": return json(": heartbeat\n\n")
            case "/api/session/active": return json(#"{"data":{}}"#)
            case "/api/session": return json("[]")
            case "/api/session/ses_1/permission/per_1/reply": return ABReply(status: stage.value)
            default: return ABReply()
            }
        }
        defer { ABStub.uninstall() }
        let box = ABBox<[AgentSnapshot]>([])
        let results = ABBox<[Bool]>([])
        let bridge = makeBridge(name: "agent-bridge-service.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) { box.value.last?.visible == true },
                "the endpoint plus stream contact makes the chip visible")
        bridge.reply(sessionID: "ses_1", requestID: "per_1", decision: .always) { ok in
            results.withLock { $0.append(ok) }
        }
        #expect(waitUntil(timeout: 5) { results.value == [true] },
                "a 200 answer for the permission reply reports success")
        stage.withLock { $0 = 500 }
        bridge.reply(sessionID: "ses_1", requestID: "per_1", decision: .once) { ok in
            results.withLock { $0.append(ok) }
        }
        #expect(waitUntil(timeout: 5) { results.value == [true, false] },
                "a 500 answer for the same reply reports failure")
        let posted = ABStub.recorded(path: "/api/session/ses_1/permission/per_1/reply")
        #expect(posted.count == 2 && posted.allSatisfy { $0.method == "POST" },
                "each call posted exactly once")
        #expect(posted.allSatisfy { $0.path.contains("ses_1") && $0.path.contains("per_1") },
                "the path carries the session id and the request id")
        let first = try #require(posted.first?.body)
        let firstJSON = try #require((try JSONSerialization.jsonObject(with: first)) as? [String: Any])
        #expect(firstJSON["decision"] as? String == "always", "the first body carries the decision")
        let second = try #require(posted.last?.body)
        let secondJSON = try #require((try JSONSerialization.jsonObject(with: second)) as? [String: Any])
        #expect(secondJSON["decision"] as? String == "once", "the failing call still sent its decision")
        bridge.stop()
    }

    @Test func testReplyFormReportsSuccessThenFailure() throws {
        writeService("agent-bridge-service.json", serviceJSON)
        let stage = ABBox(200)
        ABStub.install { request in
            switch request.url?.path ?? "" {
            case "/api/event": return json(": heartbeat\n\n")
            case "/api/session/active": return json(#"{"data":{}}"#)
            case "/api/session": return json("[]")
            case "/api/session/ses_2/form/frm_9/reply": return ABReply(status: stage.value)
            default: return ABReply()
            }
        }
        defer { ABStub.uninstall() }
        let box = ABBox<[AgentSnapshot]>([])
        let results = ABBox<[Bool]>([])
        let bridge = makeBridge(name: "agent-bridge-service.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) { box.value.last?.visible == true },
                "the endpoint plus stream contact makes the chip visible")
        bridge.replyForm(sessionID: "ses_2", formID: "frm_9", fieldKey: "choice", value: "go") { ok in
            results.withLock { $0.append(ok) }
        }
        #expect(waitUntil(timeout: 5) { results.value == [true] },
                "a 200 answer for the form reply reports success")
        stage.withLock { $0 = 500 }
        bridge.replyForm(sessionID: "ses_2", formID: "frm_9", fieldKey: "choice", value: "stop") { ok in
            results.withLock { $0.append(ok) }
        }
        #expect(waitUntil(timeout: 5) { results.value == [true, false] },
                "a 500 answer for the same reply reports failure")
        let posted = ABStub.recorded(path: "/api/session/ses_2/form/frm_9/reply")
        #expect(posted.count == 2, "each call posted exactly once")
        #expect(posted.allSatisfy { $0.path.contains("ses_2") && $0.path.contains("frm_9") },
                "the path carries the session id and the form id")
        let first = try #require(posted.first?.body)
        let firstJSON = try #require((try JSONSerialization.jsonObject(with: first)) as? [String: Any])
        let firstAnswer = try #require(firstJSON["answer"] as? [String: String])
        #expect(firstAnswer["choice"] == "go", "the first body carries the field key and value")
        let second = try #require(posted.last?.body)
        let secondJSON = try #require((try JSONSerialization.jsonObject(with: second)) as? [String: Any])
        let secondAnswer = try #require(secondJSON["answer"] as? [String: String])
        #expect(secondAnswer["choice"] == "stop", "the failing call still sent its answer")
        bridge.stop()
    }

    @Test func testInterruptIsFireAndForget() {
        writeService("agent-bridge-service.json", serviceJSON)
        ABStub.install { request in
            switch request.url?.path ?? "" {
            case "/api/event": return json(": heartbeat\n\n")
            case "/api/session/active": return json(#"{"data":{}}"#)
            case "/api/session": return json("[]")
            default: return ABReply()
            }
        }
        defer { ABStub.uninstall() }
        let box = ABBox<[AgentSnapshot]>([])
        let bridge = makeBridge(name: "agent-bridge-service.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) { box.value.last?.visible == true },
                "the bridge is up before the interrupt")
        // No completion parameter: the chip only needs the request sent.
        bridge.interrupt(sessionID: "ses_1")
        #expect(waitUntil(timeout: 5) {
            ABStub.recorded(path: "/api/session/ses_1/interrupt").count == 1
        }, "the interrupt is issued once")
        let sent = ABStub.recorded(path: "/api/session/ses_1/interrupt")
        #expect(sent.first?.method == "POST", "the interrupt is a POST")
        #expect(sent.first?.body == nil, "the interrupt carries no body")
        bridge.stop()
    }

    @Test func testFailedActivePollKeepsTheBusyState() {
        writeService("agent-bridge-service.json", serviceJSON)
        let stage = ABBox(1)
        ABStub.install { request in
            switch request.url?.path ?? "" {
            case "/api/event": return json(": heartbeat\n\n")
            case "/api/session/active":
                switch stage.value {
                case 1: return json(#"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"idle"}}}"#)
                case 2: return ABReply(status: 500)
                default: return json(#"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"running"}}}"#)
                }
            case "/api/session": return json(listJSON)
            case "/api/session/ses_a/permission", "/api/session/ses_b/permission":
                return json(#"{"data":[]}"#)
            default: return ABReply()
            }
        }
        defer { ABStub.uninstall() }
        let box = ABBox<[AgentSnapshot]>([])
        let bridge = makeBridge(name: "agent-bridge-service.json", session: abSession())
        bridge.onUpdate = { snapshot in box.withLock { $0.append(snapshot) } }
        bridge.start()
        #expect(waitUntil(timeout: 5) { box.value.last?.chip == .busy(count: 1) },
                "the first successful fetch marks one running group busy")
        stage.withLock { $0 = 2 }
        #expect(waitUntil(timeout: 5) {
            ABStub.recorded(path: "/api/session/active").count >= 2
        }, "the next fetch is attempted")
        #expect(box.value.last?.chip == .busy(count: 1),
                "a failed fetch leaves the previous busy count on the chip")
        stage.withLock { $0 = 3 }
        #expect(waitUntil(timeout: 5) { box.value.last?.chip == .busy(count: 2) },
                "a later successful fetch updates the count")
        bridge.stop()
    }
}
