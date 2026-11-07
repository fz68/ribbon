import Foundation
import Testing
@testable import RibbonCore

private let healthNow = Date(timeIntervalSince1970: 1_800_000_000)

@Suite(.serialized) final class AgentBridgeHealthTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testNoEndpointIsNotVisible() {
        #expect(!AgentBridgeHealth.visible(endpoint: false,
                                           lastContact: healthNow,
                                           now: healthNow),
                "without a registration file there is nothing to show")
    }

    @Test func testNoContactIsNotVisible() {
        #expect(!AgentBridgeHealth.visible(endpoint: true,
                                           lastContact: nil,
                                           now: healthNow),
                "a file that was never read proves nothing")
    }

    @Test func testRecentContactIsVisible() {
        let window = Theme.Timing.agentContactWindow
        #expect(AgentBridgeHealth.visible(endpoint: true,
                                          lastContact: healthNow,
                                          now: healthNow.addingTimeInterval(window - 0.001)),
                "contact just inside the window keeps the chip")
        #expect(AgentBridgeHealth.visible(endpoint: true,
                                          lastContact: healthNow,
                                          now: healthNow.addingTimeInterval(window / 2)),
                "the middle of the window keeps the chip")
    }

    @Test func testTheWindowIsExclusive() {
        let window = Theme.Timing.agentContactWindow
        #expect(!AgentBridgeHealth.visible(endpoint: true,
                                           lastContact: healthNow,
                                           now: healthNow.addingTimeInterval(window)),
                "exactly the window is already stale")
        #expect(!AgentBridgeHealth.visible(endpoint: true,
                                           lastContact: healthNow,
                                           now: healthNow.addingTimeInterval(window + 1)),
                "past the window the chip is gone")
    }

    @Test func testFutureContactStaysVisible() {
        // A clock jump backwards must not hide a service that just spoke.
        #expect(AgentBridgeHealth.visible(endpoint: true,
                                          lastContact: healthNow,
                                          now: healthNow.addingTimeInterval(-5)),
                "negative elapsed time is still recent")
    }

    @Test func testEnabledIsAConjunction() {
        #expect(!AgentBridgeHealth.visible(enabled: false, bridgeVisible: true),
                "the menu switch wins over a healthy bridge")
        #expect(!AgentBridgeHealth.visible(enabled: true, bridgeVisible: false),
                "a disabled bridge is invisible even when the user wants it")
        #expect(AgentBridgeHealth.visible(enabled: true, bridgeVisible: true),
                "both conditions must hold")
        #expect(!AgentBridgeHealth.visible(enabled: false, bridgeVisible: false))
    }
}
