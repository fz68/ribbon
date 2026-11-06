import Foundation

/// One thing the chip is waiting on: a permission decision or a form.
struct PendingRequest: Equatable {
    /// What kind of interaction resolves it.
    enum Kind: Equatable {
        case permission
        case form
    }

    /// Permission request id or form id; the key a reply/cancel event matches.
    let id: String
    let kind: Kind
    /// The action name, or the form title when the service supplies no action.
    let action: String
    /// Paths or URLs the action touches; empty when the service sent none.
    let resources: [String]
    /// Envelope time of the asking event, used to triage oldest first.
    let requestedAt: Date
}

/// One opencode session as the chip knows it.
struct AgentSession: Equatable {
    let id: String
    /// `basename` of the session directory; "?" until a directory is known.
    var shortName: String
    /// True while the session is busy or retrying.
    var isBusy: Bool
    /// Unresolved permission/form requests, in arrival order.
    var pending: [PendingRequest]
    /// Last time any event touched this session.
    var lastSeen: Date
}

/// What the chip should draw.
enum AgentChipState: Equatable {
    case off
    case idle
    case busy(count: Int)
    case awaiting(count: Int)
    case done
}

/// The pure state reduction behind the agent chip.
///
/// There is no IO and no clock inside: every entry point takes `now`, so the
/// whole state machine, including the three-second `done` decay, is testable
/// with fixed dates. The owner runs it on the event stream's serial queue and
/// republishes snapshots to the UI.
struct AgentSessionStore {
    /// How long the chip stays green after the last busy session went idle.
    static let doneDuration: TimeInterval = 3

    /// Sessions by id. Mutated only through `apply` and `replaceAll`.
    private(set) var sessions: [String: AgentSession] = [:]

    /// When the `done` state stops being drawn; nil when the chip never went
    /// busy-to-idle in this window.
    private(set) var doneUntil: Date?

    // MARK: - Reduction

    /// Applies one event at the logical time `now`.
    mutating func apply(_ event: AgentEvent, now: Date) {
        switch event.type {
        case "session.created":
            guard let id = event.sessionID else { return }
            ensureSession(id: id, directory: event.directory, now: now)
            if let name = Self.shortName(directory: event.directory) {
                sessions[id]?.shortName = name
            }
        case "session.deleted":
            guard let id = event.sessionID else { return }
            // Deleting the session drops its pending requests with it; the chip
            // must not keep asking about something that no longer exists.
            sessions.removeValue(forKey: id)
        case "session.status":
            guard let id = event.sessionID else { return }
            switch event.statusType {
            case "busy", "retry":
                setBusy(true, id: id, now: now, armDone: false)
            case "idle":
                // Status transitions are how the service normally reports
                // idle, so they arm the done window exactly like session.idle.
                setBusy(false, id: id, now: now, armDone: true)
            default:
                break
            }
        case "session.idle":
            guard let id = event.sessionID else { return }
            setBusy(false, id: id, now: now, armDone: true)
        case "permission.asked":
            guard let id = event.sessionID, let requestID = event.permissionID else { return }
            ensureSession(id: id, directory: event.directory, now: now)
            addPending(PendingRequest(id: requestID,
                                     kind: .permission,
                                     action: event.data["action"] as? String ?? "",
                                     resources: event.data["resources"] as? [String] ?? [],
                                     requestedAt: event.created),
                       to: id, now: now)
        case "permission.replied":
            // Matched by request id alone: a reply can arrive for a session the
            // store has already reconciled away, and the id is globally unique.
            removePending(id: event.permissionID)
        case "form.created":
            guard let id = event.sessionID, let formID = event.data["id"] as? String else { return }
            ensureSession(id: id, directory: event.directory, now: now)
            addPending(PendingRequest(id: formID,
                                     kind: .form,
                                     action: event.data["action"] as? String
                                         ?? event.data["title"] as? String ?? "",
                                     resources: event.data["resources"] as? [String] ?? [],
                                     requestedAt: event.created),
                       to: id, now: now)
        case "form.replied", "form.cancelled":
            removePending(id: event.data["id"] as? String)
        default:
            break
        }
    }

    /// Replaces the whole known state with a reconciled snapshot.
    ///
    /// The resync path (startup and every reconnect) has no way to know which
    /// pending requests were answered while the stream was down. The caller
    /// therefore says whether its pending arrays are authoritative:
    ///
    /// - Authoritative: the snapshot is the whole truth and replaces everything.
    /// - Not authoritative: an empty pending array means "unknown", not "none",
    ///   so an existing session with the same id keeps its pending requests. A
    ///   non-empty array still replaces, and a session absent from the snapshot
    ///   is dropped with its requests.
    ///
    /// `doneUntil` is cleared either way: a resync is not a busy-to-idle
    /// transition.
    mutating func replaceAll(sessions newSessions: [AgentSession],
                             now: Date,
                             pendingIsAuthoritative: Bool) {
        var fresh: [String: AgentSession] = [:]
        for var session in newSessions {
            session.lastSeen = now
            if session.shortName.isEmpty { session.shortName = "?" }
            if !pendingIsAuthoritative, session.pending.isEmpty,
               let existing = sessions[session.id], !existing.pending.isEmpty {
                session.pending = existing.pending
            }
            fresh[session.id] = session
        }
        sessions = fresh
        doneUntil = nil
    }

    // MARK: - Chip state

    /// The chip state at `now`.
    ///
    /// This is a method rather than the plan's `var chip` so the three-second
    /// `done` window can be evaluated against an injected clock instead of
    /// `Date()`; the reduction itself stays pure.
    func chip(now: Date) -> AgentChipState {
        let awaiting = sessions.values.filter { !$0.pending.isEmpty }.count
        if awaiting > 0 { return .awaiting(count: awaiting) }
        let busy = sessions.values.filter(\.isBusy).count
        if busy > 0 { return .busy(count: busy) }
        if let doneUntil, now < doneUntil { return .done }
        return .idle
    }

    /// The oldest unresolved request across all sessions, lower session id
    /// winning an exact time tie so the order is deterministic.
    var triageHead: (session: AgentSession, request: PendingRequest)? {
        var best: (session: AgentSession, request: PendingRequest)?
        for session in sessions.values {
            for request in session.pending {
                guard let current = best else {
                    best = (session, request)
                    continue
                }
                if Self.isOlder(request, in: session, than: current.request, in: current.session) {
                    best = (session, request)
                }
            }
        }
        return best
    }

    /// How many interactions are waiting, across every session.
    var triageCount: Int {
        sessions.values.reduce(0) { $0 + $1.pending.count }
    }

    // MARK: - Helpers

    private static func isOlder(_ request: PendingRequest, in session: AgentSession,
                                than other: PendingRequest, in otherSession: AgentSession) -> Bool {
        if request.requestedAt != other.requestedAt {
            return request.requestedAt < other.requestedAt
        }
        if session.id != otherSession.id {
            return session.id < otherSession.id
        }
        return request.id < other.id
    }

    /// `basename` of a session directory, nil when there is none to show.
    static func shortName(directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private mutating func ensureSession(id: String, directory: String?, now: Date) {
        if var session = sessions[id] {
            session.lastSeen = now
            sessions[id] = session
            return
        }
        sessions[id] = AgentSession(id: id,
                                    shortName: Self.shortName(directory: directory) ?? "?",
                                    isBusy: false,
                                    pending: [],
                                    lastSeen: now)
    }

    private mutating func addPending(_ request: PendingRequest, to id: String, now: Date) {
        guard var session = sessions[id] else { return }
        // Replayed frames must not double the count.
        if !session.pending.contains(where: { $0.id == request.id }) {
            session.pending.append(request)
        }
        session.lastSeen = now
        sessions[id] = session
    }

    /// Removes a pending request by id from whichever session holds it.
    private mutating func removePending(id: String?) {
        guard let id else { return }
        for key in Array(sessions.keys) {
            guard var session = sessions[key],
                  session.pending.contains(where: { $0.id == id }) else {
                continue
            }
            session.pending.removeAll { $0.id == id }
            sessions[key] = session
        }
    }

    private mutating func setBusy(_ busy: Bool, id: String, now: Date, armDone: Bool) {
        ensureSession(id: id, directory: nil, now: now)
        let hadBusy = busyCount > 0
        sessions[id]?.isBusy = busy
        sessions[id]?.lastSeen = now
        if busy {
            // Work resumed: an earlier done window is no longer the truth.
            doneUntil = nil
        } else if armDone, hadBusy, busyCount == 0 {
            doneUntil = now.addingTimeInterval(Self.doneDuration)
        }
    }

    private var busyCount: Int {
        sessions.values.filter(\.isBusy).count
    }
}
