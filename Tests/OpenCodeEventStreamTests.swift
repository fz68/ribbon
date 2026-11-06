import Foundation
import Testing
@testable import RibbonCore

// MARK: - Stub support

/// Thread-safe holder for a value the background queue writes.
private final class StreamBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

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

/// What one stubbed URLSession request should answer.
private struct StubReply {
    var status = 200
    /// Body chunks, delivered in order, so a frame can be split mid-line.
    var chunks: [Data] = []
    /// Keep the connection open without finishing, to exercise the idle timer.
    var hangs = false
}

/// Replays scripted responses for the event-stream and client tests.
///
/// `URLProtocol` makes the whole network layer testable without a server; the
/// recorder also captures the request so the auth header and reply body can be
/// asserted.
private final class StubURLProtocol: URLProtocol {
    private static let backend = StubBackend()

    static func install(_ handler: @escaping (URLRequest) -> StubReply) {
        backend.install(handler)
    }

    static func uninstall() {
        backend.uninstall()
    }

    static var requests: [URLRequest] { backend.requests }
    static var requestCount: Int { backend.requests.count }
    static var lastRequest: URLRequest? { backend.requests.last }
    static var lastBody: Data? { backend.lastBody }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = StubURLProtocol.backend.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: reply.status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if !reply.hangs {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class StubBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) -> StubReply)?
    private var stored: [URLRequest] = []
    private var body: Data?

    func install(_ handler: @escaping (URLRequest) -> StubReply) {
        lock.lock()
        self.handler = handler
        stored = []
        body = nil
        lock.unlock()
    }

    func uninstall() {
        lock.lock()
        handler = nil
        stored = []
        body = nil
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    func record(_ request: URLRequest) -> StubReply? {
        // URLSession hands the body over as a stream, so read it before the
        // request is stored; a client test asserts on the JSON payload.
        let body = Self.readBody(request)
        lock.lock()
        let handler = self.handler
        stored.append(request)
        self.body = body
        lock.unlock()
        return handler?(request)
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private let testEndpoint = ServiceEndpoint(url: URL(string: "http://127.0.0.1:49374")!,
                                           password: "test-password",
                                           version: "2.1.4",
                                           pid: 42)

/// One event-envelope JSON object, compact like the service sends it.
private func envelope(_ type: String,
                      ms: Double = 1_700_000_000_000,
                      directory: String = "/Users/x/projects/api",
                      data: String = "{}") -> String {
    "{\"id\":\"evt_1\",\"created\":\(ms),\"type\":\"\(type)\","
        + "\"location\":{\"directory\":\"\(directory)\"},\"data\":\(data)}"
}

/// One complete SSE frame for a payload.
private func frame(_ payload: String) -> String {
    "data: \(payload)\n\n"
}

/// Splits text into fixed-size chunks so line reassembly is exercised.
private func chunks(_ text: String, size: Int) -> [Data] {
    let bytes = Array(text.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { start in
        Data(bytes[start..<min(start + size, bytes.count)])
    }
}

// MARK: - Tests

@Suite(.serialized) final class OpenCodeEventStreamTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testSSEParserJoinsDataLinesAndIgnoresOtherFields() {
        var parser = SSELineParser()
        #expect(parser.consume(line: ": heartbeat") == nil, "a comment yields no frame")
        #expect(parser.consume(line: "event: message") == nil, "event: is ignored")
        #expect(parser.consume(line: "id: 7") == nil, "id: is ignored")
        #expect(parser.consume(line: "retry: 1000") == nil, "retry: is ignored")
        #expect(parser.consume(line: "data: {\"a\":1,") == nil, "an open frame yields nothing")
        #expect(parser.consume(line: "data: \"b\":2}") == nil, "a second data line still waits")
        #expect(parser.consume(line: "") == "{\"a\":1,\n\"b\":2}",
                "a blank line terminates the frame and joins data lines with a newline")
        #expect(parser.consume(line: "") == nil, "a comment-only frame yields nothing")

        #expect(parser.consume(line: "data: x\r") == nil, "a CRLF line is accepted")
        #expect(parser.consume(line: "") == "x", "the carriage return is not part of the payload")
    }

    @Test func testSSEParserFlushReturnsAnUnterminatedFrame() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: {\"a\":1}") == nil, "no blank line yet")
        #expect(parser.flush() == "{\"a\":1}", "EOF hands over the pending payload")
        #expect(parser.flush() == nil, "flushing clears the buffer")
    }

    @Test func testCRLFAndUnterminatedFinalFrameAreDelivered() {
        // First frame terminated by CRLF, second one never terminated at all.
        let created = envelope("session.created", data: "{\"sessionID\":\"ses_1\"}")
        let idle = envelope("session.idle", ms: 1_700_000_001_000,
                            data: "{\"sessionID\":\"ses_1\"}")
        let body = "data: \(created)\r\n\r\n" + "data: \(idle)"
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { events.value.count == 2 },
                "the CRLF frame and the EOF-flushed frame are both delivered")
        stream.stop()
        #expect(events.value.map(\.type) == ["session.created", "session.idle"],
                "both frames keep their type and order")
    }

    @Test func testStreamReassemblesChunksAndDeliversOnlySubscribedEvents() {
        let body = [
            ": heartbeat",
            "",
            frame(envelope("server.connected", directory: "/tmp", data: "{}")),
            frame(envelope("session.text.delta",
                           data: "{\"sessionID\":\"ses_1\",\"delta\":\"hi\"}")),
            frame(envelope("permission.asked",
                           ms: 1_700_000_002_000,
                           data: "{\"id\":\"per_1\",\"sessionID\":\"ses_1\","
                               + "\"action\":\"bash\",\"resources\":[\"ls\",\"-la\"]}")),
        ].joined(separator: "\n") + "\n"

        StubURLProtocol.install { _ in
            StubReply(chunks: chunks(body, size: 7))
        }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let resyncs = StreamBox(0)
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onResync = { resyncs.withLock { $0 += 1 } }
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { events.value.count == 1 },
                "the subscribed frame is delivered despite the chunked body")
        stream.stop()

        #expect(resyncs.value == 2,
                "one resync for the subscribe and one for the server.connected frame")
        #expect(events.value.count == 1, "the delta frame is dropped by the prefilter")
        let event = events.value.first
        #expect(event?.type == "permission.asked", "the delivered frame keeps its type")
        #expect(event?.sessionID == "ses_1", "the session id is lifted out of data")
        #expect(event?.permissionID == "per_1", "the permission id is lifted out of data")
        #expect(event?.created == Date(timeIntervalSince1970: 1_700_000_002),
                "the millisecond envelope time becomes a date")
        #expect(event?.directory == "/Users/x/projects/api",
                "the envelope directory is kept for the session short name")
        #expect(event?.data["action"] as? String == "bash", "the raw data is kept for the reducer")
        #expect(event?.data["resources"] as? [String] == ["ls", "-la"],
                "resources are kept for the reducer")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/event",
                "the stream subscribes to /api/event")
        #expect(StubURLProtocol.lastRequest?.url?.query == nil,
                "no types query parameter is sent; the server ignores it")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
                    == "Basic " + Data("opencode:test-password".utf8).base64EncodedString(),
                "every request carries the Basic auth header")
    }

    @Test func testUnsubscribedFramesProduceNoEvents() {
        // A body with only deltas: the prefilter must drop every frame.
        let body = frame(envelope("session.text.delta",
                                  data: "{\"sessionID\":\"ses_1\",\"delta\":\"hi\"}"))
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 0.05, maximumDelay: 0.05))
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        // A second request proves the first body ended and every line was read.
        #expect(waitUntil(timeout: 5) { StubURLProtocol.requestCount >= 2 },
                "the finite stream ended and the client reconnected")
        stream.stop()
        #expect(events.value.isEmpty, "a delta frame never becomes an AgentEvent")
    }

    @Test func testServerConnectedTriggersResyncOnly() {
        let body = frame(envelope("server.connected", directory: "/tmp", data: "{}"))
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let resyncs = StreamBox(0)
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onResync = { resyncs.withLock { $0 += 1 } }
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { resyncs.value >= 2 },
                "the subscribe and the server.connected frame each ask for a resync")
        stream.stop()
        #expect(events.value.isEmpty, "server.connected is never delivered as an event")
    }

    @Test func testSubscribedFrameQuotingServerConnectedIsStillDelivered() {
        // A real event whose payload literally contains the marker must not be
        // swallowed by the resync branch.
        let data = "{\"sessionID\":\"ses_1\",\"status\":{\"type\":\"busy\"},"
            + "\"meta\":{\"type\":\"server.connected\"}}"
        let body = frame(envelope("session.status", ms: 1_700_000_003_000, data: data))
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let resyncs = StreamBox(0)
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onResync = { resyncs.withLock { $0 += 1 } }
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { events.value.count == 1 },
                "a subscribed frame is checked against the types before the marker")
        stream.stop()
        #expect(events.value.first?.type == "session.status", "the status event is delivered")
        #expect(resyncs.value == 1, "the embedded marker does not trigger a resync")
    }

    @Test func testSpacedJSONPermissionAskedIsDelivered() {
        // Whitespace after a colon must not cost a permission request.
        let payload = "{ \"id\": \"evt_1\", \"created\": 1700000004000, "
            + "\"type\": \"permission.asked\", "
            + "\"location\": { \"directory\": \"/tmp/spaced\" }, "
            + "\"data\": { \"id\": \"per_1\", \"sessionID\": \"ses_1\", "
            + "\"action\": \"bash\" } }"
        let body = "data: \(payload)\n\n"
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { events.value.count == 1 },
                "the tolerant scanner admits a spaced envelope")
        stream.stop()
        #expect(events.value.first?.type == "permission.asked", "the request reaches the reducer")
        #expect(events.value.first?.permissionID == "per_1", "the permission id is decoded")
    }

    @Test func testNestedSubscribedTypeAdmitsTheFrame() {
        // Deliberate tradeoff: an inner type that looks subscribed admits the
        // frame, costing one decode the reducer then ignores.
        let data = "{\"sessionID\":\"ses_1\",\"delta\":\"...\","
            + "\"meta\":{\"type\":\"session.status\"}}"
        let body = frame(envelope("session.text.delta", ms: 1_700_000_005_000, data: data))
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let events = StreamBox<[AgentEvent]>([])
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 30, maximumDelay: 30))
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { events.value.count == 1 },
                "the nested type admits the frame instead of dropping it")
        stream.stop()
        #expect(events.value.first?.type == "session.text.delta",
                "the reducer receives the real envelope type and ignores it")
    }

    @Test func testIdleConnectionIsCancelledAndRetried() {
        StubURLProtocol.install { _ in StubReply(hangs: true) }
        defer { StubURLProtocol.uninstall() }

        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 0.1,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 0.05, maximumDelay: 0.05))
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { StubURLProtocol.requestCount >= 2 },
                "a silent connection is declared dead and reconnected")
        stream.stop()
    }

    @Test func testStreamRetryPolicyDoublesAndCaps() {
        let policy = StreamRetryPolicy.standard
        #expect(policy.delay(forAttempt: 0) == 1, "the first retry waits one second")
        #expect(policy.delay(forAttempt: 1) == 2, "the second retry doubles")
        #expect(policy.delay(forAttempt: 2) == 4, "each retry doubles again")
        #expect(policy.delay(forAttempt: 4) == 16, "the sequence keeps doubling")
        #expect(policy.delay(forAttempt: 5) == 30, "the wait is capped at thirty seconds")
        #expect(policy.delay(forAttempt: 50) == 30, "the cap holds for any later attempt")

        let fast = StreamRetryPolicy(initialDelay: 0.1, maximumDelay: 0.3)
        #expect(fast.delay(forAttempt: 0) == 0.1, "an injected initial delay is honoured")
        #expect(fast.delay(forAttempt: 1) == 0.2, "the injected policy doubles")
        #expect(fast.delay(forAttempt: 2) == 0.3, "the injected cap applies")
    }

    @Test func testBackoffGrowsWhenAConnectionDropsWithoutFrames() {
        // 200 with an empty body: the connect succeeds, then drops instantly.
        // A subscribe must not count as proof of life.
        StubURLProtocol.install { _ in StubReply() }
        defer { StubURLProtocol.uninstall() }

        let policy = StreamRetryPolicy(initialDelay: 0.02, maximumDelay: 0.5)
        let stream = EventStream(session: stubSession(), idleTimeout: 5, retryPolicy: policy)
        stream.update(endpoint: testEndpoint)

        // A connection that ends without a single line must schedule the next
        // attempt every time. A stored handle for an already finished run, or an
        // idle timer left spinning, would stop the retries here.
        #expect(waitUntil(timeout: 5) { StubURLProtocol.requestCount >= 4 },
                "the client keeps reconnecting after immediate closes")
        #expect(stream.nextRetryDelay > policy.initialDelay,
                "a connection that never delivers a line keeps backing off")
        #expect(stream.nextRetryDelay >= policy.delay(forAttempt: 2),
                "the delay has grown several steps, not just once")
        stream.stop()
    }

    @Test func testHeartbeatsFireActivityOnceAndNeverAnEvent() {
        // Two heartbeats inside the throttle window, then the finite body ends
        // and the stub replays the same lines on reconnect: the throttle must
        // hold across connections as well.
        let body = ": heartbeat\n\n: heartbeat\n\n"
        StubURLProtocol.install { _ in StubReply(chunks: [Data(body.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let activities = StreamBox(0)
        let events = StreamBox<[AgentEvent]>([])
        let stream = EventStream(session: stubSession(),
                                 idleTimeout: 5,
                                 retryPolicy: StreamRetryPolicy(initialDelay: 0.05, maximumDelay: 0.05))
        stream.onActivity = { activities.withLock { $0 += 1 } }
        stream.onEvent = { event in events.withLock { $0.append(event) } }
        stream.update(endpoint: testEndpoint)

        #expect(waitUntil(timeout: 5) { activities.value >= 1 },
                "a heartbeat comment counts as activity")
        #expect(waitUntil(timeout: 5) { StubURLProtocol.requestCount >= 2 },
                "the finite body ends and the stream reconnects")
        stream.stop()
        #expect(activities.value == 1,
                "two heartbeats within five seconds notify exactly once")
        #expect(events.value.isEmpty, "a heartbeat is never delivered as an event")
    }

    @Test func testBackoffResetsAfterARealLine() {
        StubURLProtocol.install { _ in StubReply() }
        defer { StubURLProtocol.uninstall() }

        let policy = StreamRetryPolicy(initialDelay: 0.02, maximumDelay: 0.5)
        let stream = EventStream(session: stubSession(), idleTimeout: 5, retryPolicy: policy)
        stream.update(endpoint: testEndpoint)
        #expect(waitUntil(timeout: 5) { StubURLProtocol.requestCount >= 3 },
                "the empty connections grow the backoff first")
        #expect(stream.nextRetryDelay > policy.initialDelay, "the backoff grew")

        // Next connection hangs after one (unsubscribed) line. Any line proves
        // the service is alive, so the backoff returns to its initial delay.
        let line = frame(envelope("session.text.delta",
                                  data: "{\"sessionID\":\"ses_1\",\"delta\":\"x\"}"))
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(line.utf8)], hangs: true)
        }
        #expect(waitUntil(timeout: 5) { stream.nextRetryDelay == policy.initialDelay },
                "the first delivered line resets the backoff")
        stream.stop()
    }

    @Test func testClientReadsLiveWrappedActiveShape() async throws {
        // The live 2.1.4 response is wrapped in a data object.
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(
                #"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"idle"}}}"#.utf8)])
        }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let ids = try await client.activeSessionIDs()
        #expect(ids == ["ses_a"], "only running sessions inside data count as active")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/session/active",
                "the live shape is read from /api/session/active")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
                    == "Basic " + Data("opencode:test-password".utf8).base64EncodedString(),
                "the auth header is derived from the endpoint password")
    }

    @Test func testClientFallsBackToBareMapAndStringMap() async throws {
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(
                #"{"ses_a":{"type":"running"},"ses_b":{"type":"retry"}}"#.utf8)])
        }
        defer { StubURLProtocol.uninstall() }
        var client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let bareMap = try await client.activeSessionIDs()
        #expect(bareMap == ["ses_a"], "a bare map of state objects is accepted")

        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(#"{"ses_a":"running","ses_b":"opaque"}"#.utf8)])
        }
        client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let stringMap = try await client.activeSessionIDs()
        #expect(stringMap == ["ses_a", "ses_b"],
                "a map of opaque values counts every key as running")
    }

    @Test func testClientFallsBackToArrayOfIDs() async throws {
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(#"["ses_a","ses_b"]"#.utf8)])
        }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let ids = try await client.activeSessionIDs()
        #expect(ids == ["ses_a", "ses_b"], "an array of ids is taken as the running set")
    }

    @Test func testClientInfoReturnsTheDecodedObject() async throws {
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(#"{"version":"2.1.4","id":"abc"}"#.utf8)])
        }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let info = try await client.info()
        #expect(info["version"] as? String == "2.1.4", "info returns the decoded object")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/info", "info probes /api/info")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
                    == "Basic " + Data("opencode:test-password".utf8).base64EncodedString(),
                "the health probe is authenticated too")
    }

    @Test func testClientRejectsAnUnknownActiveShape() async {
        StubURLProtocol.install { _ in StubReply(chunks: [Data("42".utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        await #expect(throws: OpenCodeClientError.transport) {
            _ = try await client.activeSessionIDs()
        }
    }

    @Test func testClientRepliesToPermissionWithDecisionBody() async throws {
        StubURLProtocol.install { _ in StubReply(status: 204) }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        try await client.replyPermission(sessionID: "ses_1", requestID: "per_1", decision: .always)

        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST", "the reply is a POST")
        #expect(StubURLProtocol.lastRequest?.url?.path
                    == "/api/session/ses_1/permission/per_1/reply",
                "the reply targets the locked session and request")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type")
                    == "application/json", "the reply is JSON")
        let body = try #require(StubURLProtocol.lastBody)
        let object = try #require((try JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect(object["decision"] as? String == "always", "the raw value is the wire decision")
    }

    @Test func testClientPercentEncodesIDs() async throws {
        StubURLProtocol.install { _ in StubReply(status: 204) }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        try await client.replyPermission(sessionID: "ses_50%", requestID: "per_?x", decision: .once)

        let url = try #require(StubURLProtocol.lastRequest?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath
                    == "/api/session/ses_50%25/permission/per_%3Fx/reply",
                "ids are encoded once, with no path split and no double encoding")
        #expect(!(StubURLProtocol.lastRequest?.url?.absoluteString.contains("ses_50%/") ?? true),
                "a percent in an id does not leak into the raw path")
    }

    @Test func testClientReportsTypedErrors() async {
        StubURLProtocol.install { _ in StubReply(status: 500) }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        await #expect(throws: OpenCodeClientError.badStatus(500)) {
            _ = try await client.info()
        }
    }

    @Test func testClientListsSessionsFromWrappedAndBareShapes() async throws {
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(
                #"{"data":[{"id":"ses_a","title":"fix tests","location":{"directory":"/x/api"}},{"title":"no id"}],"cursor":{"next":"x"}}"#
                    .utf8)])
        }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let sessions = try await client.listSessions(limit: 2)
        #expect(sessions == [SessionSummary(id: "ses_a", title: "fix tests", directory: "/x/api")],
                "the wrapped page decodes and an entry without an id is skipped")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/session",
                "the list comes from the session endpoint")
        #expect(StubURLProtocol.lastRequest?.url?.query == "limit=2",
                "the page size is passed through")

        // A bare array is the documented fallback shape.
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(#"[{"id":"ses_b","location":{"directory":"/y"}}]"#.utf8)])
        }
        let bare = try await OpenCodeClient(endpoint: testEndpoint, session: stubSession())
            .listSessions()
        #expect(bare == [SessionSummary(id: "ses_b", title: nil, directory: "/y")],
                "a bare array page is accepted")
    }

    @Test func testClientRejectsAnUnknownSessionListShape() async {
        StubURLProtocol.install { _ in StubReply(chunks: [Data(#"{"data":42}"#.utf8)]) }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        await #expect(throws: OpenCodeClientError.transport) {
            _ = try await client.listSessions()
        }
    }

    @Test func testClientDecodesPendingRequests() async throws {
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(
                #"{"data":[{"id":"per_1","sessionID":"ses_1","action":"bash","resources":["ls","-la"]},{"sessionID":"ses_1"}]}"#
                    .utf8)])
        }
        defer { StubURLProtocol.uninstall() }

        let client = OpenCodeClient(endpoint: testEndpoint, session: stubSession())
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let pending = try await client.pendingRequests(sessionID: "ses_1", now: fetchedAt)

        #expect(pending.count == 1, "an entry without an id is skipped")
        #expect(pending.first?.id == "per_1", "the request id is decoded")
        #expect(pending.first?.kind == .permission, "fetched pendings are permissions")
        #expect(pending.first?.action == "bash", "the action is decoded")
        #expect(pending.first?.resources == ["ls", "-la"], "resources are decoded")
        #expect(pending.first?.requestedAt == fetchedAt,
                "the fetch time fills the timestamp the payload does not carry")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/session/ses_1/permission",
                "pendings are read per session")
        #expect(StubURLProtocol.lastRequest?.url?.query == nil,
                "the pending list takes no query")

        // A bare array is the documented fallback shape.
        StubURLProtocol.install { _ in
            StubReply(chunks: [Data(#"[{"id":"per_2","action":"edit"}]"#.utf8)])
        }
        let bare = try await OpenCodeClient(endpoint: testEndpoint, session: stubSession())
            .pendingRequests(sessionID: "ses_2")
        #expect(bare.map(\.id) == ["per_2"], "a bare array is accepted")
        #expect(bare.first?.resources.isEmpty == true, "missing resources are empty")
    }

    @Test func testEndpointDescriptionNeverContainsPassword() {
        let endpoint = ServiceEndpoint(url: URL(string: "http://127.0.0.1:1")!,
                                       password: "super-secret",
                                       version: "2.1.4",
                                       pid: 7)
        #expect(!String(describing: endpoint).contains("super-secret"),
                "description must not leak the password")
        #expect(!endpoint.debugDescription.contains("super-secret"),
                "debugDescription must not leak the password")
        #expect(String(describing: endpoint).contains("127.0.0.1"),
                "the non-secret parts stay readable")

        let mirrored = Mirror(reflecting: endpoint).children
            .map { "\($0.label ?? "")=\($0.value)" }
            .joined(separator: ",")
        #expect(!mirrored.contains("super-secret"),
                "Mirror(reflecting:) must not leak the password either")
        #expect(mirrored.contains("<redacted>"), "the mirror shows a placeholder")
    }
}
