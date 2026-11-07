import Foundation

/// One decoded SSE frame from opencode's `/api/event` stream.
///
/// Every event shares one envelope (`id`, `created`, `type`, `location`,
/// `data`), but the fields the reducer needs sit in different places per type.
/// They are lifted into properties at decode time so the reducer never has to
/// know the envelope shape, while the raw `data` object is kept for the parts
/// only some types carry (`action`, `resources`, form fields).
struct AgentEvent: Equatable {
    /// Event type, e.g. `permission.asked`.
    let type: String
    /// Envelope `created`, a millisecond epoch converted to a date.
    let created: Date
    /// Owning session, when the event has one.
    let sessionID: String?
    /// Permission request id (`data.id` for asked, `data.requestID` for replied).
    let permissionID: String?
    /// Session status the store understands (`busy`, `idle`, `retry`).
    ///
    /// `session.status` carries its own kind. opencode 2.2.6's execution events
    /// carry none, so they are mapped here into the same vocabulary: a started
    /// execution is `busy`; a succeeded, failed or interrupted execution is
    /// `idle` (the turn ended - a failed or interrupted turn still counts as a
    /// finished turn, so the chip's green done flash fires for it too).
    let statusType: String?
    /// Envelope `location.directory`, falling back to the payload's own
    /// location. It gives the session short name without an extra request.
    let directory: String?
    /// Session title, present on `session.created`.
    let title: String?
    /// Parent session id when this event concerns a subagent session; nil for a
    /// top-level session. Decoded opportunistically from the payload.
    let parentID: String?
    /// The untouched `data` object, so the reducer can read action/resources.
    let data: [String: Any]

    /// Compares the typed fields and the raw payload.
    ///
    /// `[String: Any]` cannot be compared by the synthesized conformance, so the
    /// payload goes through `NSDictionary`, which understands nested JSON.
    static func == (lhs: AgentEvent, rhs: AgentEvent) -> Bool {
        lhs.type == rhs.type
            && lhs.created == rhs.created
            && lhs.sessionID == rhs.sessionID
            && lhs.permissionID == rhs.permissionID
            && lhs.statusType == rhs.statusType
            && lhs.directory == rhs.directory
            && lhs.title == rhs.title
            && lhs.parentID == rhs.parentID
            && NSDictionary(dictionary: lhs.data).isEqual(to: rhs.data)
    }
}

extension AgentEvent {
    /// Decodes the JSON payload of one SSE `data:` field.
    ///
    /// Tolerant on purpose: the service makes no schema stability promise, so a
    /// missing field yields a nil/empty value and an unreadable payload yields
    /// nil instead of throwing. One odd frame must never kill the stream.
    static func decode(_ payload: String) -> AgentEvent? {
        guard let bytes = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        let data = object["data"] as? [String: Any] ?? [:]
        let location = object["location"] as? [String: Any]
        let dataLocation = data["location"] as? [String: Any]
        let directory = location?["directory"] as? String ?? dataLocation?["directory"] as? String

        let sessionID: String?
        let permissionID: String?
        let statusType: String?
        switch type {
        case "permission.asked":
            sessionID = data["sessionID"] as? String
            permissionID = data["id"] as? String
            statusType = nil
        case "permission.replied":
            sessionID = data["sessionID"] as? String
            // The reply carries requestID; some versions echo id instead.
            permissionID = data["requestID"] as? String ?? data["id"] as? String
            statusType = nil
        case "session.created":
            // Older payloads put the session id under `id`.
            sessionID = data["sessionID"] as? String ?? data["id"] as? String
            permissionID = nil
            statusType = nil
        case "session.status":
            sessionID = data["sessionID"] as? String
            permissionID = nil
            statusType = (data["status"] as? [String: Any])?["type"] as? String
        case "session.deleted", "session.idle":
            sessionID = data["sessionID"] as? String
            permissionID = nil
            statusType = nil
        case "session.execution.started":
            // 2.2.6's busy boundary: `created` equals `session.time.busy` to the
            // millisecond. Mapped to the store's vocabulary here so the reducer
            // stays the same for both generations.
            sessionID = data["sessionID"] as? String
            permissionID = nil
            statusType = "busy"
        case "session.execution.succeeded", "session.execution.failed",
             "session.execution.interrupted":
            // 2.2.6's idle boundary, 0-3 ms after `session.time.idle`. Every
            // outcome means the turn ended; a failed turn is still "not busy
            // any more", so it arms the same done window.
            sessionID = data["sessionID"] as? String
            permissionID = nil
            statusType = "idle"
        case "form.created", "form.replied", "form.cancelled":
            // The nested `form` object is expected from the static schema; the
            // flat shape is tolerated as a fallback. The live form event itself
            // is still unverified (A5).
            let form = data["form"] as? [String: Any]
            sessionID = data["sessionID"] as? String ?? form?["sessionID"] as? String
            permissionID = nil
            statusType = nil
        case "tui.session.select":
            // Payload unobserved. `id` is accepted only when it looks like a
            // session id; an evt_ id must not create a phantom session.
            let rawID = data["id"] as? String
            sessionID = data["sessionID"] as? String
                ?? (rawID?.hasPrefix("ses_") == true ? rawID : nil)
            permissionID = nil
            statusType = nil
        default:
            sessionID = data["sessionID"] as? String
            permissionID = nil
            statusType = nil
        }

        // A missing timestamp becomes the epoch rather than "now": the reducer
        // is pure, and a fabricated current time would make it untestable.
        let milliseconds = (object["created"] as? NSNumber)?.doubleValue ?? 0
        return AgentEvent(type: type,
                          created: Date(timeIntervalSince1970: milliseconds / 1000),
                          sessionID: sessionID,
                          permissionID: permissionID,
                          statusType: statusType,
                          directory: directory,
                          title: data["title"] as? String,
                          parentID: data["parentID"] as? String,
                          data: data)
    }
}
