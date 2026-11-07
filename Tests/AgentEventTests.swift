import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class AgentEventTests {
    /// The exact 2.2.6 frames: envelope `id`/`created`/`type`/`data`, and the
    /// execution events carry only the session id.
    private func frame(_ type: String, created: Double = 1_794_034_436_661) -> String {
        "{\"id\":\"evt_1\",\"created\":\(created),\"type\":\"\(type)\","
            + "\"data\":{\"sessionID\":\"ses_1\"}}"
    }

    @Test(arguments: [
        ("session.execution.started", "busy"),
        ("session.execution.succeeded", "idle"),
        ("session.execution.failed", "idle"),
        ("session.execution.interrupted", "idle"),
    ])
    func testExecutionEventsMapToTheStoreVocabulary(_ pair: (String, String)) throws {
        let (type, expected) = pair
        let event = try #require(AgentEvent.decode(frame(type)))

        #expect(event.type == type)
        #expect(event.sessionID == "ses_1", "the execution event carries its session")
        #expect(event.statusType == expected,
                "started is busy; any ended turn is idle, whatever its outcome")
        #expect(event.permissionID == nil, "no permission id is invented")
        #expect(event.created == Date(timeIntervalSince1970: 1_794_034_436.661),
                "the millisecond envelope timestamp is kept")
    }

    @Test func testExecutionEventsPassTheStreamPrefilter() {
        for type in ["session.execution.started",
                     "session.execution.succeeded",
                     "session.execution.failed",
                     "session.execution.interrupted"] {
            #expect(EventStream.subscribedTypes.contains(type),
                    "\(type) must be subscribed or the prefilter drops the frame")
        }
    }

    @Test func testExecutionEventWithoutSessionIsTolerated() throws {
        let event = try #require(AgentEvent.decode(
            "{\"id\":\"evt_2\",\"created\":1,\"type\":\"session.execution.started\",\"data\":{}}"))
        #expect(event.sessionID == nil, "a malformed frame decodes without a session")
        #expect(event.statusType == "busy", "the type alone still carries the meaning")
    }
}
