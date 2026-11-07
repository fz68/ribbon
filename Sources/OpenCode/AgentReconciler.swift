import Foundation

/// Builds the store's session snapshot from one reconciliation fetch.
///
/// The event stream only reports transitions; after a start or a reconnect the
/// truth is whatever the service answers now. This mapping is pure, so the merge
/// rules (which sessions exist, how busy is decided, when old pending state
/// survives) are testable without a network or a clock.
enum AgentReconciler {
    /// Merges a fetch into `[AgentSession]`.
    ///
    /// A session is included when it is listed, active, or has pending requests.
    /// Union instead of intersection on purpose: the list endpoint is paginated,
    /// so an active session can legally be absent from a page and must still
    /// show as busy.
    ///
    /// - Parameters:
    ///   - activeIDs: sessions the service currently calls `running`.
    ///   - listedSessions: the session list page.
    ///   - pendingByID: pending permissions when the fetch completed, nil when
    ///     it did not. Nil means "unknown", so the previous pending state is
    ///     kept instead of being wiped.
    ///   - previous: the store as it stands, used for names and pending state
    ///     the fetch cannot supply.
    ///   - now: stamped as `lastSeen` on every session.
    static func sessions(activeIDs: Set<String>,
                         listedSessions: [SessionSummary],
                         pendingByID: [String: [PendingRequest]]?,
                         previous: AgentSessionStore,
                         now: Date) -> [AgentSession] {
        // First entry wins on a duplicate id, so a paged list that repeats an
        // entry stays deterministic.
        var listed: [String: SessionSummary] = [:]
        for summary in listedSessions where listed[summary.id] == nil {
            listed[summary.id] = summary
        }

        var ids = Set(listed.keys)
        ids.formUnion(activeIDs)
        if let pendingByID { ids.formUnion(pendingByID.keys) }

        return ids.sorted().map { id in
            let summary = listed[id]
            let prior = previous.sessions[id]
            // The merged directory, not the page alone: a page that omits the
            // location must not lose a name the bridge already knew.
            let directory = summary?.directory ?? prior?.directory
            let shortName = AgentSessionStore.shortName(directory: directory)
                ?? prior?.shortName
                ?? "?"
            let pending: [PendingRequest]
            if let pendingByID {
                pending = pendingByID[id] ?? []
            } else {
                pending = prior?.pending ?? []
            }
            return AgentSession(id: id,
                                shortName: shortName,
                                isBusy: activeIDs.contains(id),
                                pending: pending,
                                lastSeen: now,
                                // Only the list page knows parentage. A session
                                // kept because it is active or pending but
                                // missing from the page has no known parent and
                                // therefore forms its own group.
                                parentID: summary?.parentID,
                                directory: directory,
                                title: summary?.title ?? prior?.title)
        }
    }
}
