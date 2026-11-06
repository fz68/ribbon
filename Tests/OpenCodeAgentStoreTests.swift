import Foundation
import Testing
@testable import RibbonCore

/// Builds an event through the real decoder, so the reducer tests also pin the
/// envelope-to-agent mapping.
private func makeEvent(_ type: String,
                       ms: Double = 1_700_000_000_000,
                       directory: String? = nil,
                       data: [String: Any] = [:]) -> AgentEvent? {
    var envelope: [String: Any] = [
        "id": "evt_\(Int(ms))",
        "created": ms,
        "type": type,
        "data": data,
    ]
    if let directory { envelope["location"] = ["directory": directory] }
    guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
    return AgentEvent.decode(String(decoding: bytes, as: UTF8.self))
}

private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    baseTime.addingTimeInterval(seconds)
}

@Suite(.serialized) final class OpenCodeAgentStoreTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testSessionCreatedUsesDirectoryBasename() throws {
        var store = AgentSessionStore()
        let created = try #require(makeEvent("session.created",
                                             directory: "/Users/x/projects/api",
                                             data: ["sessionID": "ses_1", "title": "fix tests"]))
        store.apply(created, now: baseTime)

        #expect(store.sessions["ses_1"]?.shortName == "api",
                "the session short name is the directory basename")
        #expect(store.sessions["ses_1"]?.isBusy == false, "a new session is not busy")
        #expect(store.triageCount == 0, "a new session waits on nothing")
        #expect(store.chip(now: baseTime) == .idle, "one idle session is an idle chip")

        let unknown = try #require(makeEvent("session.created", data: ["sessionID": "ses_2"]))
        store.apply(unknown, now: baseTime)
        #expect(store.sessions["ses_2"]?.shortName == "?",
                "a session without a directory falls back to ?")
    }

    @Test func testBusySessionsAggregateAndDoneDecays() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.created", to: &store, data: ["sessionID": "ses_2"])

        try apply("session.status", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "busy"]])
        #expect(store.chip(now: at(1)) == .busy(count: 1), "one busy session counts one")

        try apply("session.status", at: 2, to: &store,
                  data: ["sessionID": "ses_2", "status": ["type": "retry"]])
        #expect(store.chip(now: at(2)) == .busy(count: 2),
                "retry counts as busy and sessions aggregate")
        #expect(store.sessions["ses_2"]?.isBusy == true, "retry marks the session busy")

        // The first idle leaves the other session busy: no done window yet.
        try apply("session.idle", at: 3, to: &store, data: ["sessionID": "ses_1"])
        #expect(store.chip(now: at(3)) == .busy(count: 1),
                "a still-busy session keeps the chip busy")
        #expect(store.doneUntil == nil, "partial idle does not arm the done window")

        // The last busy session goes idle at t=4, so done lasts until t=7.
        try apply("session.idle", at: 4, to: &store, data: ["sessionID": "ses_2"])
        #expect(store.chip(now: at(4)) == .done, "the last idle arms the done window")
        #expect(store.chip(now: at(6.9)) == .done, "done is still drawn just before the window ends")
        #expect(store.chip(now: at(7)) == .idle, "done decays after three seconds")
        #expect(store.chip(now: at(30)) == .idle, "done never comes back by itself")
    }

    @Test func testStatusIdleAlsoArmsTheDoneWindow() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.status", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "busy"]])
        #expect(store.chip(now: at(1)) == .busy(count: 1), "status busy sets the flag")

        // The service reports idle through session.status; that path must arm
        // the same done window as session.idle.
        try apply("session.status", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "idle"]])
        #expect(store.doneUntil == at(5), "status idle arms a three second window")
        #expect(store.chip(now: at(2)) == .done, "the transition shows done")
        #expect(store.chip(now: at(5)) == .idle, "the window decays")
    }

    @Test func testIdleWithoutBusyNeverArmsDone() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.idle", at: 1, to: &store, data: ["sessionID": "ses_1"])
        #expect(store.chip(now: at(1)) == .idle,
                "idle with no preceding busy state is not a done transition")
        #expect(store.doneUntil == nil, "nothing armed a done window")

        // A status idle on a session that was never busy is equally inert.
        try apply("session.status", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "idle"]])
        #expect(store.chip(now: at(2)) == .idle,
                "an idle that is not a transition stays idle")
    }

    @Test func testAwaitingOutranksBusyAndAggregatesPerSession() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.status", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "busy"]])

        try apply("permission.asked", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_1", "action": "bash",
                         "resources": ["ls", "-la"]])
        #expect(store.chip(now: at(2)) == .awaiting(count: 1),
                "awaiting outranks busy")
        #expect(store.triageCount == 1, "one pending request is counted")

        // A second request in the same session still counts one awaiting session
        // but two queued interactions.
        try apply("permission.asked", at: 3, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_2", "action": "edit"])
        #expect(store.chip(now: at(3)) == .awaiting(count: 1),
                "the chip count is sessions with work, not raw requests")
        #expect(store.triageCount == 2, "triage counts every pending request")

        let head = store.triageHead
        #expect(head?.request.id == "per_1", "the oldest request is first")
        #expect(head?.request.kind == .permission, "the kind records what resolves it")
        #expect(head?.request.action == "bash", "the action comes from the raw data")
        #expect(head?.request.resources == ["ls", "-la"], "resources come from the raw data")
        #expect(head?.request.requestedAt == at(2), "requestedAt is the envelope time")
    }

    @Test func testRepliedRemovesPendingEvenWithStaleSessionID() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("permission.asked", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_1", "action": "bash"])
        #expect(store.chip(now: at(1)) == .awaiting(count: 1), "the request is queued")

        // The reply names a session the store no longer knows (a race with a
        // resync); the request id alone must clear the queue.
        try apply("permission.replied", at: 2, to: &store,
                  data: ["sessionID": "ses_other", "requestID": "per_1", "reply": "once"])
        #expect(store.triageCount == 0, "the reply wins the race and removes the request")
        #expect(store.chip(now: at(2)) == .idle, "no pending and no busy work is idle")

        // A replayed asked frame must not double the count.
        try apply("permission.asked", at: 3, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_2", "action": "bash"])
        try apply("permission.asked", at: 3, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_2", "action": "bash"])
        #expect(store.triageCount == 1, "a duplicate asked frame is ignored")
    }

    @Test func testFormLifecycleQueuesAndClears() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("form.created", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "id": "frm_1", "title": "Choose model"])
        #expect(store.chip(now: at(1)) == .awaiting(count: 1), "a form also awaits")
        #expect(store.triageHead?.request.kind == .form, "the pending kind is form")
        #expect(store.triageHead?.request.action == "Choose model",
                "the form title stands in for the action")

        try apply("form.cancelled", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "id": "frm_1"])
        #expect(store.triageCount == 0, "a cancelled form leaves the queue")
        #expect(store.chip(now: at(2)) == .idle, "nothing pending means idle")

        try apply("form.created", at: 3, to: &store,
                  data: ["sessionID": "ses_1", "id": "frm_2", "title": "Pick scope"])
        try apply("form.replied", at: 4, to: &store,
                  data: ["sessionID": "ses_1", "id": "frm_2"])
        #expect(store.triageCount == 0, "a replied form leaves the queue")
    }

    @Test func testTriageTieBreaksOnSessionID() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_b"])
        try apply("session.created", to: &store, data: ["sessionID": "ses_a"])
        try apply("permission.asked", at: 5, to: &store,
                  data: ["sessionID": "ses_b", "id": "per_b", "action": "bash"])
        try apply("permission.asked", at: 5, to: &store,
                  data: ["sessionID": "ses_a", "id": "per_a", "action": "bash"])

        #expect(store.triageCount == 2, "both requests are queued")
        #expect(store.triageHead?.session.id == "ses_a",
                "an exact time tie goes to the lower session id")
        #expect(store.triageHead?.request.id == "per_a", "the tie winner's request is first")
        #expect(store.chip(now: at(5)) == .awaiting(count: 2),
                "two sessions wait, so the chip shows two")
    }

    @Test func testDeletedSessionDropsItsPendingRequests() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("permission.asked", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_1", "action": "bash"])
        try apply("session.deleted", at: 2, to: &store, data: ["sessionID": "ses_1"])

        #expect(store.sessions.isEmpty, "the session is gone")
        #expect(store.triageCount == 0, "its requests are gone with it")
        #expect(store.chip(now: at(2)) == .idle, "an empty store is idle")
    }

    @Test func testReplaceAllRebuildsFromReconciledState() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.status", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "status": ["type": "busy"]])
        try apply("permission.asked", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_1", "action": "bash"])

        store.replaceAll(sessions: [
            AgentSession(id: "ses_x", shortName: "", isBusy: true, pending: [],
                         lastSeen: .distantPast),
        ], now: at(10), pendingIsAuthoritative: true)

        #expect(store.sessions.count == 1, "the snapshot replaces the old state")
        #expect(store.sessions["ses_x"] != nil, "the reconciled session is present")
        #expect(store.sessions["ses_x"]?.shortName == "?", "an empty short name becomes ?")
        #expect(store.sessions["ses_x"]?.lastSeen == at(10), "the snapshot marks the session seen now")
        #expect(store.triageCount == 0, "an authoritative snapshot drops stale pending requests")
        #expect(store.chip(now: at(10)) == .busy(count: 1), "busy comes from the snapshot")
        #expect(store.doneUntil == nil, "a resync is not a busy-to-idle transition")

        store.replaceAll(sessions: [], now: at(11), pendingIsAuthoritative: true)
        #expect(store.chip(now: at(11)) == .idle, "an empty snapshot is idle")
    }

    @Test func testNonAuthoritativeReplaceAllKeepsPendingForSurvivingSessions() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])
        try apply("session.created", to: &store, data: ["sessionID": "ses_2"])
        try apply("permission.asked", at: 1, to: &store,
                  data: ["sessionID": "ses_1", "id": "per_1", "action": "bash"])
        try apply("form.created", at: 2, to: &store,
                  data: ["sessionID": "ses_2", "id": "frm_1", "title": "Pick"])

        // A transient reconnect only knows the session list, so an empty pending
        // array means "unknown" and the existing requests survive.
        store.replaceAll(sessions: [
            AgentSession(id: "ses_1", shortName: "api", isBusy: true, pending: [],
                         lastSeen: .distantPast),
        ], now: at(10), pendingIsAuthoritative: false)

        #expect(store.sessions.count == 1, "sessions missing from the snapshot are dropped")
        #expect(store.sessions["ses_2"] == nil, "the absent session is gone")
        #expect(store.triageCount == 1, "the surviving session keeps its pending request")
        #expect(store.triageHead?.request.id == "per_1", "the kept request is the same one")
        #expect(store.chip(now: at(10)) == .awaiting(count: 1),
                "the preserved request still drives the chip")
        #expect(store.doneUntil == nil, "a resync is still not a done transition")

        // A non-empty incoming pending array is authoritative for that session.
        let replacement = PendingRequest(id: "per_9", kind: .permission,
                                         action: "edit", resources: [], requestedAt: at(9))
        store.replaceAll(sessions: [
            AgentSession(id: "ses_1", shortName: "api", isBusy: false, pending: [replacement],
                         lastSeen: .distantPast),
        ], now: at(11), pendingIsAuthoritative: false)
        #expect(store.triageCount == 1, "the incoming request replaces the old one")
        #expect(store.triageHead?.request.id == "per_9", "the snapshot's request wins")
    }

    @Test func testEventsMissingTheirIDsAreIgnored() throws {
        var store = AgentSessionStore()
        try apply("session.created", to: &store, data: ["sessionID": "ses_1"])

        // permission.asked without a session id or without a request id cannot
        // be queued, and must not crash or invent a session.
        try apply("permission.asked", at: 1, to: &store,
                  data: ["id": "per_1", "action": "bash"])
        #expect(store.triageCount == 0, "a request without a session is ignored")
        #expect(store.sessions.count == 1, "no placeholder session is invented")

        try apply("permission.asked", at: 2, to: &store,
                  data: ["sessionID": "ses_1", "action": "bash"])
        #expect(store.triageCount == 0, "a request without an id is ignored")

        // form.created without an id has nothing to reply to either.
        try apply("form.created", at: 3, to: &store,
                  data: ["sessionID": "ses_1", "title": "Pick"])
        #expect(store.triageCount == 0, "a form without an id is ignored")

        try apply("session.deleted", to: &store, data: [:])
        #expect(store.sessions.count == 1, "a delete without a session id changes nothing")
    }

    // MARK: - Helper

    private func apply(_ type: String,
                       at seconds: TimeInterval,
                       to store: inout AgentSessionStore,
                       data: [String: Any]) throws {
        let event = try #require(makeEvent(type, ms: 1_700_000_000_000 + seconds * 1000, data: data))
        store.apply(event, now: at(seconds))
    }

    private func apply(_ type: String,
                       to store: inout AgentSessionStore,
                       data: [String: Any]) throws {
        try apply(type, at: 0, to: &store, data: data)
    }
}
