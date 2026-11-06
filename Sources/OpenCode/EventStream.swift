import Foundation

/// The reconnect schedule for the event stream.
///
/// The service is local, so the first retry is quick; doubling the wait keeps a
/// service that is down for a while from being hammered. The counter resets as
/// soon as a connection proves it is alive by delivering a line, so a healthy
/// connection that drops reconnects fast again.
struct StreamRetryPolicy: Equatable {
    /// Wait before the first retry.
    let initialDelay: TimeInterval
    /// Ceiling for the doubling sequence.
    let maximumDelay: TimeInterval

    /// 1s, 2s, 4s ... capped at 30s, as verified against the service.
    static let standard = StreamRetryPolicy(initialDelay: 1, maximumDelay: 30)

    /// The wait before retry number `attempt`, counting from zero.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return initialDelay }
        var delay = initialDelay
        for _ in 0..<attempt {
            delay *= 2
            if delay >= maximumDelay { return maximumDelay }
        }
        return min(delay, maximumDelay)
    }
}

/// Accumulates SSE lines into frame payloads.
///
/// Kept separate from the socket so frame semantics can be tested without a
/// stream: a blank line ends a frame, `data:` lines join with a newline (SSE
/// allows a payload to span several lines), and every other field is irrelevant
/// to this client.
struct SSELineParser {
    private var dataLines: [String] = []

    /// Feeds one line (without its terminator).
    ///
    /// - Returns: the joined payload when the line ends a frame, otherwise nil.
    mutating func consume(line rawLine: String) -> String? {
        // Tolerate CRLF even though the transport already strips the CR.
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return flush()
        }
        // Comment lines are heartbeats. They carry no data and, per the SSE
        // spec, are ignored - the caller still counts them as activity.
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        // event:, id: and retry: are tolerated and ignored: the payload itself
        // carries the event type.
        return nil
    }

    /// Returns the payload of a frame that ended without a blank line.
    ///
    /// Used at EOF: a server that closes mid-frame still said something, and the
    /// data lines already collected are the only complete information there is.
    mutating func flush() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        return payload
    }
}

/// Reads opencode's SSE event stream and delivers filtered, decoded events.
///
/// The server ignores the `types` query parameter (verified on 2.1.4) and sends
/// every event, including high-rate `session.text.delta` frames. The payload is
/// therefore filtered as a string before any JSON decode, which keeps the cost
/// of an interesting frame off the hot path.
///
/// Thread contract: `onEvent`, `onResync` and `onActivity` are always called on
/// the private serial queue, never on the main thread. All three closures are
/// set once, before `update(endpoint:)`, and never mutated afterwards: the
/// delivery path reads them from that queue without additional synchronisation.
/// `update(endpoint:)` and `stop()` may be called from any thread.
final class EventStream {
    /// Delivers one subscribed event. Set once, before `update(endpoint:)`.
    var onEvent: ((AgentEvent) -> Void)?
    /// Signals that the subscription is (re)established; the owner should do a
    /// full reconciliation (active sessions + pending state) on every call. Set
    /// once, before `update(endpoint:)`.
    var onResync: (() -> Void)?

    /// Fires for any received line once the stream has not notified for a while,
    /// heartbeats and frame boundaries included.
    ///
    /// Separate from `onEvent` because liveness is not the same thing as a
    /// business event: the service keeps the connection open with `: heartbeat`
    /// comments during long quiet stretches, so a health check that only listens
    /// to events would hide a perfectly healthy chip. Throttled by
    /// `activityNotifyInterval` so a delta burst cannot wake the owner per line.
    /// Called on the stream queue; set once, before `update(endpoint:)`.
    var onActivity: (() -> Void)?

    /// Six lines of silence a minute apart is still alive; a minute of total
    /// silence is not, so the connection is presumed dead and rebuilt.
    static let defaultIdleTimeout: TimeInterval = 60

    /// Event types this client cares about. Their compact-JSON `type` form is
    /// what the prefilter looks for.
    static let subscribedTypes = [
        "permission.asked",
        "permission.replied",
        "session.created",
        "session.deleted",
        "session.status",
        "session.idle",
        "form.created",
        "form.replied",
        "form.cancelled",
    ]

    private static let serverConnectedMarker = "\"type\":\"server.connected\""

    /// Minimum gap between `onActivity` calls. Any line proves liveness, but a
    /// delta burst would otherwise wake the owner dozens of times a second.
    private static let activityNotifyInterval: TimeInterval = 5

    private let session: URLSession
    private let retryPolicy: StreamRetryPolicy
    private let idleTimeout: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var endpoint: ServiceEndpoint?
    private var task: Task<Void, Never>?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = DispatchTime.now()
    /// When `onActivity` last fired. The throttle spans connections on purpose:
    /// a reconnect within the interval does not need a second wake-up, and the
    /// resync that follows a subscribe is already contact.
    private var lastActivityNotify: DispatchTime?
    private var generation = 0
    private var attempt = 0
    private var stopped = true
    /// True between `connect()` and `finish()`; stops a cancelled task's late
    /// error from tearing down the connection that replaced it.
    private var connectionOpen = false

    /// - Parameters:
    ///   - session: injected so tests replay a scripted body via URLProtocol.
    ///   - idleTimeout: overridable so tests do not wait a real minute.
    ///   - retryPolicy: overridable so tests do not wait a real second.
    ///   - queue: one serial background queue shared by callbacks and timers.
    init(session: URLSession = .shared,
         idleTimeout: TimeInterval = EventStream.defaultIdleTimeout,
         retryPolicy: StreamRetryPolicy = .standard,
         queue: DispatchQueue = DispatchQueue(label: "local.ribbon.opencode.events")) {
        self.session = session
        self.idleTimeout = idleTimeout
        self.retryPolicy = retryPolicy
        self.queue = queue
    }

    deinit {
        // A dropped stream must not leave its connection or timer running.
        lock.lock()
        stopped = true
        generation += 1
        task?.cancel()
        task = nil
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()
    }

    /// The delay the next reconnect would use. Exposed so tests can pin the
    /// backoff state without waiting real seconds.
    var nextRetryDelay: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return retryPolicy.delay(forAttempt: attempt)
    }

    /// Points the stream at an endpoint and (re)starts it.
    ///
    /// Always restarts, even when the endpoint is unchanged: a service restart
    /// can invalidate the old connection without changing the URL.
    func update(endpoint: ServiceEndpoint) {
        lock.lock()
        self.endpoint = endpoint
        generation += 1
        stopped = false
        attempt = 0
        connectionOpen = false
        task?.cancel()
        task = nil
        cancelIdleTimerLocked()
        lock.unlock()
        connect()
    }

    /// Cancels the connection and every pending retry.
    func stop() {
        lock.lock()
        stopped = true
        generation += 1
        connectionOpen = false
        endpoint = nil
        task?.cancel()
        task = nil
        cancelIdleTimerLocked()
        lock.unlock()
    }

    // MARK: - Connection

    private func connect() {
        lock.lock()
        guard !stopped, let endpoint else {
            lock.unlock()
            return
        }
        // A new generation on every connect makes a cancelled predecessor's late
        // completion a no-op instead of a second teardown of the new stream.
        generation += 1
        let generation = self.generation
        lastActivity = DispatchTime.now()
        connectionOpen = true
        let request = Self.eventRequest(endpoint: endpoint, idleTimeout: idleTimeout)
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(request: request, generation: generation)
        }

        lock.lock()
        // `connectionOpen` guards against storing a handle whose run already
        // finished and nilled the slot; only a live connection owns the slot.
        if self.generation == generation, !stopped, connectionOpen {
            self.task = task
            startIdleTimerLocked(generation: generation)
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    private func run(request: URLRequest, generation: Int) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw OpenCodeClientError.transport
            }
            guard subscribe(generation: generation) else { return }
            // The line sequence is not used: Foundation drops empty lines, and
            // an empty line is exactly what terminates an SSE frame. Raw bytes
            // are split here instead, which also keeps a frame boundary intact
            // when the transport hands over a partial line. Each connection owns
            // its parser, so the per-line lock covers only the idle clock.
            var parser = SSELineParser()
            var buffer: [UInt8] = []
            for try await byte in bytes {
                if Task.isCancelled { break }
                if byte == 0x0A {
                    handle(line: String(decoding: buffer, as: UTF8.self),
                           parser: &parser, generation: generation)
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    buffer.append(byte)
                }
            }
            // The last line may arrive without a trailing newline. Feeding it
            // keeps the idle clock honest; the parser still waits for the blank
            // line that ends the frame.
            if !buffer.isEmpty, !Task.isCancelled {
                handle(line: String(decoding: buffer, as: UTF8.self),
                       parser: &parser, generation: generation)
            }
            // A stream that ends mid-frame (EOF without the blank line) still
            // delivered data lines; hand them over through the same path.
            if !Task.isCancelled, let payload = parser.flush(),
               isCurrent(generation: generation) {
                deliver(payload)
            }
            finish(generation: generation)
        } catch {
            finish(generation: generation)
        }
    }

    /// Whether `generation` is still the live connection. Synchronous on
    /// purpose: `NSLock` may not be taken directly from an async context.
    private func isCurrent(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation && !stopped
    }

    /// Marks the subscription live and announces the resync.
    ///
    /// The backoff counter is deliberately not reset here: a service that
    /// accepts the connection and drops it without a single frame would never
    /// back off. `handle(line:)` resets it on the first real line instead.
    @discardableResult
    private func subscribe(generation: Int) -> Bool {
        lock.lock()
        guard generation == self.generation, !stopped else {
            lock.unlock()
            return false
        }
        lock.unlock()
        queue.async { [weak self] in
            self?.onResync?()
        }
        return true
    }

    /// Ends the current connection and schedules the retry.
    private func finish(generation: Int) {
        lock.lock()
        guard generation == self.generation, !stopped else {
            lock.unlock()
            return
        }
        // The idle timer belongs to this generation. Even when the connection is
        // already closed (the handle was never stored, or a previous finish ran),
        // the timer must be cancelled here: a timer left behind would fire
        // forever with no connection to cancel and no retry to schedule, because
        // this path exits before the retry is booked.
        guard connectionOpen else {
            cancelIdleTimerLocked()
            lock.unlock()
            return
        }
        connectionOpen = false
        task = nil
        cancelIdleTimerLocked()
        let delay = retryPolicy.delay(forAttempt: attempt)
        attempt += 1
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let eligible = generation == self.generation && !self.stopped
            self.lock.unlock()
            if eligible { self.connect() }
        }
    }

    private static func eventRequest(endpoint: ServiceEndpoint, idleTimeout: TimeInterval) -> URLRequest {
        // No `types` query parameter: 2.1.4 ignores it, and sending one would
        // only suggest a filter that is not happening.
        var request = URLRequest(url: endpoint.url.appendingPathComponent("api/event"))
        request.httpMethod = "GET"
        request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The app's idle timer is the authority. The transport backstop must sit
        // clearly above it: URLSession's default timeoutIntervalForRequest is
        // 60s, equal to the default idle timeout, and would race the app's own
        // check instead of backing it up.
        request.timeoutInterval = idleTimeout * 2 + 10
        return request
    }

    // MARK: - Frames

    /// Consumes one line: resets the idle clock, then parses and delivers.
    private func handle(line: String, parser: inout SSELineParser, generation: Int) {
        lock.lock()
        guard generation == self.generation, !stopped else {
            lock.unlock()
            return
        }
        // Any line - a heartbeat comment, a delta, a frame boundary - proves the
        // connection is alive. The idle timeout follows every line; the owner is
        // woken at most once per interval so a delta burst stays cheap.
        let now = DispatchTime.now()
        lastActivity = now
        if connectionOpen { attempt = 0 }
        let notify = lastActivityNotify.map {
            Double(now.uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000_000
                >= Self.activityNotifyInterval
        } ?? true
        if notify { lastActivityNotify = now }
        lock.unlock()

        if notify {
            queue.async { [weak self] in
                self?.onActivity?()
            }
        }

        if let payload = parser.consume(line: line) {
            deliver(payload)
        }
    }

    /// Routes one completed frame.
    ///
    /// Subscription is checked first on purpose: a subscribed frame whose data
    /// happens to quote `"type":"server.connected"` is still a real event and
    /// must not be swallowed by the resync check.
    private func deliver(_ payload: String) {
        if Self.isSubscribed(payload) {
            if let event = AgentEvent.decode(payload) {
                queue.async { [weak self] in
                    self?.onEvent?(event)
                }
            }
            return
        }
        if payload.contains(Self.serverConnectedMarker) {
            queue.async { [weak self] in
                self?.onResync?()
            }
        }
    }

    /// Whether a payload contains one of the subscribed types.
    ///
    /// The fast path matches the compact JSON the service emits today. If that
    /// misses, a tolerant scan checks every `"type"` key, allows whitespace
    /// after the colon and compares the quoted value. A nested `type` inside a
    /// tool payload can therefore admit an uninteresting frame; that only costs
    /// one decode and the reducer ignores unknown types, while the alternative -
    /// a spaced envelope silently dropping a permission request - is worse.
    static func isSubscribed(_ payload: String) -> Bool {
        if subscribedTypes.contains(where: { payload.contains("\"type\":\"\($0)\"") }) {
            return true
        }
        return containsSubscribedTypeValue(payload)
    }

    private static func containsSubscribedTypeValue(_ payload: String) -> Bool {
        var searchStart = payload.startIndex
        while let keyRange = payload.range(of: "\"type\"", range: searchStart..<payload.endIndex) {
            var index = skipWhitespace(in: payload, from: keyRange.upperBound)
            guard index < payload.endIndex, payload[index] == ":" else {
                searchStart = keyRange.upperBound
                continue
            }
            index = skipWhitespace(in: payload, from: payload.index(after: index))
            guard index < payload.endIndex, payload[index] == "\"" else {
                searchStart = keyRange.upperBound
                continue
            }
            let valueStart = payload.index(after: index)
            guard let valueEnd = payload[valueStart...].firstIndex(of: "\"") else {
                return false
            }
            if subscribedTypes.contains(String(payload[valueStart..<valueEnd])) {
                return true
            }
            searchStart = payload.index(after: valueEnd)
        }
        return false
    }

    private static func skipWhitespace(in text: String, from index: String.Index) -> String.Index {
        var index = index
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    // MARK: - Idle timer

    private func startIdleTimerLocked(generation: Int) {
        cancelIdleTimerLocked()
        // A fraction of the timeout keeps detection prompt without a busy loop;
        // the floor keeps a test-sized timeout from spinning.
        let interval = max(0.02, min(5, idleTimeout / 4))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.checkIdle(generation: generation)
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleTimerLocked() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func checkIdle(generation: Int) {
        lock.lock()
        guard generation == self.generation, !stopped, connectionOpen else {
            lock.unlock()
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastActivity.uptimeNanoseconds
        let expired = Double(elapsed) / 1_000_000_000 >= idleTimeout
        let task = expired ? self.task : nil
        lock.unlock()
        guard let task else { return }
        task.cancel()
        finish(generation: generation)
    }
}
