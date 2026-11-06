import Foundation

/// The decision a permission card submits.
///
/// The raw value is exactly what the API expects in the reply body, so the
/// mapping cannot drift by accident.
enum AgentDecision: String {
    case once
    case always
    case reject
}

/// The failures a request can report to the chip layer.
enum OpenCodeClientError: Error, Equatable {
    /// The service answered, but not with a success status.
    case badStatus(Int)
    /// The request never produced a usable HTTP response: connection refused,
    /// timeout, cancelled, or a body that does not parse as the expected shape.
    case transport
}

/// The fields a reconciled session needs from `GET /api/session`.
///
/// Decoded separately from `AgentSession` so the transport type stays free of
/// chip concerns (busy is not in the list response; it comes from active ids).
struct SessionSummary: Equatable {
    let id: String
    /// The main session that owns this subagent session; nil for a top-level
    /// session. opencode nests exactly one level deep.
    let parentID: String?
    let title: String?
    let directory: String?
}

/// A typed client for one opencode service.
///
/// Authentication is derived from the endpoint and attached to every request.
/// The client holds no state of its own, so rebuilding it after a service
/// restart costs nothing.
struct OpenCodeClient {
    let endpoint: ServiceEndpoint
    /// Injected so tests can replay fixed responses through a URLProtocol stub.
    let session: URLSession

    /// How long one request may take. The service is local, so ten seconds is
    /// already generous and keeps a wedged service from blocking the UI path.
    static let requestTimeout: TimeInterval = 10

    init(endpoint: ServiceEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// GET `/api/info`, used as the health probe.
    func info() async throws -> [String: Any] {
        let data = try await send("GET", "api/info")
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenCodeClientError.transport
        }
        return object
    }

    /// GET `/api/session/active`.
    ///
    /// The live 2.1.4 shape is `{"data": {"ses_...": {"type": "running"}}}`; the
    /// older/plain shapes are still accepted because the endpoint has no schema
    /// promise. Only a session the service calls `running` is active; a state
    /// object with any other type is a session it still knows but is not
    /// working on.
    func activeSessionIDs() async throws -> Set<String> {
        let data = try await send("GET", "api/session/active")
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw OpenCodeClientError.transport
        }
        if let dictionary = object as? [String: Any] {
            // Live shape: the map is wrapped in a `data` object. A session id
            // always starts with ses_, so `data` can never be a session key.
            if let wrapped = dictionary["data"] as? [String: Any] {
                return Self.runningIDs(fromSessionMap: wrapped)
            }
            // Fallback: the bare map of id to state, or id to an opaque string.
            return Self.runningIDs(fromSessionMap: dictionary)
        }
        // Fallback: a plain array of running session ids.
        if let ids = object as? [String] {
            return Set(ids)
        }
        throw OpenCodeClientError.transport
    }

    /// POST `/api/session/{sessionID}/permission/{requestID}/reply`.
    func replyPermission(sessionID: String, requestID: String, decision: AgentDecision) async throws {
        struct Reply: Encodable {
            let decision: String
        }
        let body = try JSONEncoder().encode(Reply(decision: decision.rawValue))
        let path = "api/session/\(Self.encodePathComponent(sessionID))"
            + "/permission/\(Self.encodePathComponent(requestID))/reply"
        _ = try await send("POST", path, body: body)
    }

    /// GET `/api/session?limit=N`.
    ///
    /// The live service wraps the page as `{"data": [...], "cursor": {...}}`; a
    /// bare array is accepted as well so a shape change cannot blank the chip.
    /// Entries without an id are skipped rather than failing the page.
    func listSessions(limit: Int = 50) async throws -> [SessionSummary] {
        let data = try await send("GET", "api/session",
                                  queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        let entries = try Self.dataEntries(from: data)
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let location = entry["location"] as? [String: Any]
            return SessionSummary(id: id,
                                  // JSON null decodes to nil here, which is the
                                  // top-level-session case.
                                  parentID: entry["parentID"] as? String,
                                  title: entry["title"] as? String,
                                  directory: location?["directory"] as? String)
        }
    }

    /// GET `/api/session/{sessionID}/permission`.
    ///
    /// Live 2.1.4 answers `{"data": [Permission.Request...]}`; a bare array is
    /// accepted as a fallback. The payload has no timestamp, so `now` (the fetch
    /// time) becomes `requestedAt`: the store only uses that to order triage,
    /// and a fetched request is the oldest information available for it.
    func pendingRequests(sessionID: String, now: Date = Date()) async throws -> [PendingRequest] {
        let path = "api/session/\(Self.encodePathComponent(sessionID))/permission"
        let data = try await send("GET", path)
        let entries = try Self.dataEntries(from: data)
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return PendingRequest(id: id,
                                  kind: .permission,
                                  action: entry["action"] as? String ?? "",
                                  resources: entry["resources"] as? [String] ?? [],
                                  requestedAt: now)
        }
    }

    /// Decodes a response that is either a bare array of objects or `{"data": [...]}`.
    private static func dataEntries(from data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw OpenCodeClientError.transport
        }
        if let array = object as? [[String: Any]] {
            return array
        }
        if let wrapper = object as? [String: Any],
           let array = wrapper["data"] as? [[String: Any]] {
            return array
        }
        throw OpenCodeClientError.transport
    }

    // MARK: - Decoding

    /// Extracts ids whose state object says `running`.
    ///
    /// Accepts both the `{id: {type: "running"}}` map and a `{id: "..."}` map
    /// whose values are opaque; in the latter case every key is taken as
    /// running, matching the "here is the list of running sessions" meaning.
    private static func runningIDs(fromSessionMap map: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        for (id, value) in map {
            if let state = value as? [String: Any] {
                if state["type"] as? String == "running" { ids.insert(id) }
            } else if (value as? String) != nil {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Requests

    private static let pathComponentAllowed: CharacterSet = {
        // urlPathAllowed keeps "/", which would split an id into extra path
        // segments; ids are opaque values and must stay one segment.
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? value
    }

    private func request(_ method: String,
                         _ path: String,
                         queryItems: [URLQueryItem] = [],
                         body: Data? = nil) -> URLRequest {
        // `path` is already percent-encoded; URLComponents.percentEncodedPath
        // installs it verbatim, where appendingPathComponent would double-encode
        // an id that contains '%'.
        var url = endpoint.url
        if var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) {
            let base = components.percentEncodedPath
            let prefix = base.hasSuffix("/") ? String(base.dropLast()) : base
            components.percentEncodedPath = prefix + "/" + path
            if !queryItems.isEmpty { components.queryItems = queryItems }
            if let built = components.url { url = built }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    private func send(_ method: String,
                      _ path: String,
                      queryItems: [URLQueryItem] = [],
                      body: Data? = nil) async throws -> Data {
        let request = request(method, path, queryItems: queryItems, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeClientError.transport
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenCodeClientError.badStatus(http.statusCode)
            }
            return data
        } catch let error as OpenCodeClientError {
            throw error
        } catch {
            // URLSession reports refused connections, timeouts and cancellation
            // as NSError; the caller only needs to know the service did not
            // answer.
            throw OpenCodeClientError.transport
        }
    }
}
