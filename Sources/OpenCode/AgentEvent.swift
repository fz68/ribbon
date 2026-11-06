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
    /// `session.status` only: the new status kind (`idle`, `busy`, `retry`).
    let statusType: String?
    /// Envelope `location.directory`, falling back to the payload's own
    /// location. It gives the session short name without an extra request.
    let directory: String?
    /// Session title, present on `session.created`.
    let title: String?
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
        case "form.created", "form.replied", "form.cancelled":
            sessionID = data["sessionID"] as? String
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
                          data: data)
    }
}
