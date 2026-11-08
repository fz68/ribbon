import Foundation
import Testing
@testable import RibbonCore

private let healthNow = Date(timeIntervalSince1970: 1_800_000_000)
private let contactWindow = Theme.Timing.agentContactWindow

@Suite(.serialized) final class AgentBridgeHealthTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test(arguments: visibilityCases)
    func testContactWindowVisibility(_ testCase: VisibilityCase) {
        let visible = AgentBridgeHealth.visible(endpoint: testCase.endpoint,
                                                lastContact: testCase.lastContact,
                                                now: healthNow.addingTimeInterval(testCase.nowOffset))
        #expect(visible == testCase.expected, "\(testCase.testDescription)")
    }

    @Test(arguments: conjunctionCases)
    func testEnabledIsAConjunction(_ testCase: ConjunctionCase) {
        let visible = AgentBridgeHealth.visible(enabled: testCase.enabled,
                                                bridgeVisible: testCase.bridgeVisible)
        #expect(visible == testCase.expected, "\(testCase.testDescription)")
    }
}

/// One case of the three-argument `visible` overload: whether the locator reports
/// a service, the last contact exactly as the bridge records it, and the instant
/// to evaluate at, expressed as an offset from `healthNow`.
struct VisibilityCase: Sendable, CustomTestStringConvertible {
    let endpoint: Bool
    /// `nil` means no contact was ever recorded.
    let lastContact: Date?
    /// Seconds added to `healthNow` to form the instant being evaluated.
    let nowOffset: Double
    let expected: Bool
    let testDescription: String
}

private let visibilityCases: [VisibilityCase] = [
    VisibilityCase(endpoint: false, lastContact: healthNow, nowOffset: 0, expected: false,
                   testDescription: "without a registration file there is nothing to show"),
    VisibilityCase(endpoint: true, lastContact: nil, nowOffset: 0, expected: false,
                   testDescription: "a file that was never read proves nothing"),
    VisibilityCase(endpoint: true, lastContact: healthNow, nowOffset: contactWindow - 0.001,
                   expected: true,
                   testDescription: "contact just inside the window keeps the chip"),
    VisibilityCase(endpoint: true, lastContact: healthNow, nowOffset: contactWindow / 2,
                   expected: true,
                   testDescription: "the middle of the window keeps the chip"),
    VisibilityCase(endpoint: true, lastContact: healthNow, nowOffset: contactWindow,
                   expected: false,
                   testDescription: "exactly the window is already stale"),
    VisibilityCase(endpoint: true, lastContact: healthNow, nowOffset: contactWindow + 1,
                   expected: false,
                   testDescription: "past the window the chip is gone"),
    // A clock jump backwards must not hide a service that just spoke.
    VisibilityCase(endpoint: true, lastContact: healthNow, nowOffset: -5, expected: true,
                   testDescription: "negative elapsed time is still recent"),
]

/// One case of the two-argument `visible` overload: the menu switch and the
/// bridge's own health, and what their conjunction produces.
struct ConjunctionCase: Sendable, CustomTestStringConvertible {
    let enabled: Bool
    let bridgeVisible: Bool
    let expected: Bool
    let testDescription: String
}

private let conjunctionCases: [ConjunctionCase] = [
    ConjunctionCase(enabled: false, bridgeVisible: true, expected: false,
                    testDescription: "the menu switch wins over a healthy bridge"),
    ConjunctionCase(enabled: true, bridgeVisible: false, expected: false,
                    testDescription: "a disabled bridge is invisible even when the user wants it"),
    ConjunctionCase(enabled: true, bridgeVisible: true, expected: true,
                    testDescription: "both conditions must hold"),
    ConjunctionCase(enabled: false, bridgeVisible: false, expected: false,
                    testDescription: "neither condition holds, so the chip is hidden"),
]
