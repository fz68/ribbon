import Foundation
import Testing
@testable import RibbonCore

private let reconcileNow = Date(timeIntervalSince1970: 1_800_000_000)

private func summary(_ id: String,
                     parentID: String? = nil,
                     directory: String? = nil,
                     title: String? = nil) -> SessionSummary {
    SessionSummary(id: id, parentID: parentID, title: title, directory: directory)
}

private func pending(_ id: String, action: String = "bash") -> PendingRequest {
    PendingRequest(id: id, kind: .permission, action: action, resources: [], requestedAt: reconcileNow)
}

private func session(_ id: String,
                     shortName: String,
                     busy: Bool = false,
                     pending requests: [PendingRequest] = []) -> AgentSession {
    AgentSession(id: id, shortName: shortName, isBusy: busy, pending: requests, lastSeen: .distantPast)
}

@Suite(.serialized) final class AgentReconcilerTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testBusyComesFromActiveIDs() {
        let sessions = AgentReconciler.sessions(
            activeIDs: ["ses_a"],
            listedSessions: [summary("ses_a"), summary("ses_b")],
            pendingByID: [:],
            previous: AgentSessionStore(),
            now: reconcileNow
        )

        #expect(sessions.map(\.id) == ["ses_a", "ses_b"], "sessions come back in id order")
        #expect(sessions.first { $0.id == "ses_a" }?.isBusy == true,
                "an active id is busy")
        #expect(sessions.first { $0.id == "ses_b" }?.isBusy == false,
                "a listed but inactive session is idle")
        #expect(sessions.allSatisfy { $0.lastSeen == reconcileNow },
                "the snapshot marks every session as seen now")
    }

    @Test func testShortNamePrefersDirectoryThenPreviousThenQuestionMark() {
        var previous = AgentSessionStore()
        previous.replaceAll(sessions: [
            session("ses_a", shortName: "old"),
            session("ses_b", shortName: "kept"),
        ], now: reconcileNow, pendingIsAuthoritative: true)

        let sessions = AgentReconciler.sessions(
            activeIDs: [],
            listedSessions: [
                summary("ses_a", directory: "/Users/x/projects/api"),
                summary("ses_b"),
                summary("ses_c"),
            ],
            pendingByID: [:],
            previous: previous,
            now: reconcileNow
        )

        #expect(sessions.first { $0.id == "ses_a" }?.shortName == "api",
                "a known directory wins")
        #expect(sessions.first { $0.id == "ses_b" }?.shortName == "kept",
                "a missing directory keeps the previous name")
        #expect(sessions.first { $0.id == "ses_c" }?.shortName == "?",
                "a session never seen before falls back to ?")
    }

    @Test func testDuplicateListEntriesUseTheFirst() {
        let sessions = AgentReconciler.sessions(
            activeIDs: [],
            listedSessions: [
                summary("ses_a", directory: "/x/first"),
                summary("ses_a", directory: "/x/second"),
            ],
            pendingByID: [:],
            previous: AgentSessionStore(),
            now: reconcileNow
        )

        #expect(sessions.count == 1, "the duplicate collapses to one session")
        #expect(sessions.first?.shortName == "first", "the first entry wins")
    }

    @Test func testAuthoritativePendingReplacesAndClears() {
        var previous = AgentSessionStore()
        previous.replaceAll(sessions: [
            session("ses_a", shortName: "a", pending: [pending("per_old")]),
            session("ses_b", shortName: "b", pending: [pending("per_stale")]),
        ], now: reconcileNow, pendingIsAuthoritative: true)

        let sessions = AgentReconciler.sessions(
            activeIDs: [],
            listedSessions: [summary("ses_a"), summary("ses_b")],
            pendingByID: ["ses_a": [pending("per_new")], "ses_b": []],
            previous: previous,
            now: reconcileNow
        )

        #expect(sessions.first { $0.id == "ses_a" }?.pending.map(\.id) == ["per_new"],
                "the fetched request replaces the previous one")
        #expect(sessions.first { $0.id == "ses_b" }?.pending.isEmpty == true,
                "an empty fetched array means nothing is pending")
    }

    @Test func testNilPendingKeepsThePreviousState() {
        var previous = AgentSessionStore()
        previous.replaceAll(sessions: [
            session("ses_a", shortName: "a", pending: [pending("per_old")]),
        ], now: reconcileNow, pendingIsAuthoritative: true)

        // The pending fetch failed, so pending is unknown and the store's
        // incremental state must survive the session reconcile.
        let sessions = AgentReconciler.sessions(
            activeIDs: ["ses_a"],
            listedSessions: [summary("ses_a", directory: "/x/api")],
            pendingByID: nil,
            previous: previous,
            now: reconcileNow
        )

        #expect(sessions.count == 1, "the listed session is present")
        #expect(sessions.first?.isBusy == true, "busy still comes from active ids")
        #expect(sessions.first?.pending.map(\.id) == ["per_old"],
                "unknown pending preserves what the stream already knew")
        #expect(sessions.first?.shortName == "api", "the name still updates")
    }

    @Test func testDirectoryIsCarriedFromTheList() {
        let sessions = AgentReconciler.sessions(
            activeIDs: ["ses_active_only"],
            listedSessions: [
                summary("ses_parent"),
                summary("ses_child", directory: "/x/api"),
            ],
            pendingByID: [:],
            previous: AgentSessionStore(),
            now: reconcileNow
        )

        #expect(sessions.first { $0.id == "ses_child" }?.directory == "/x/api",
                "the listed directory reaches the built session for jumps")
    }

    @Test func testSessionsMissingFromTheListAreKept() {
        // The list endpoint is paginated: an active session or one with a
        // pending request must not disappear because a page omitted it.
        let sessions = AgentReconciler.sessions(
            activeIDs: ["ses_ghost"],
            listedSessions: [summary("ses_listed", directory: "/x/listed")],
            pendingByID: ["ses_pending": [pending("per_1")]],
            previous: AgentSessionStore(),
            now: reconcileNow
        )

        #expect(sessions.map(\.id) == ["ses_ghost", "ses_listed", "ses_pending"],
                "active and pending-only sessions are included")
        #expect(sessions.first { $0.id == "ses_ghost" }?.isBusy == true,
                "an active session missing from the page is still busy")
        #expect(sessions.first { $0.id == "ses_ghost" }?.shortName == "?",
                "with no directory and no history the name is unknown")
        #expect(sessions.first { $0.id == "ses_pending" }?.pending.map(\.id) == ["per_1"],
                "the pending-only session keeps its request")
        #expect(sessions.first { $0.id == "ses_pending" }?.isBusy == false,
                "a pending-only session is not busy")
    }
}
