import Foundation
import Testing
@testable import RibbonCore

private let pressStart = Date(timeIntervalSince1970: 1_800_000_000)
private let pressThreshold: TimeInterval = 0.5

private func pressTime(_ offset: TimeInterval) -> Date {
    pressStart.addingTimeInterval(offset)
}

@Suite(.serialized) final class AgentChipPressTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testTapWhenReleasedBeforeTheThreshold() {
        var press = AgentChipPress(threshold: pressThreshold)
        _ = press.press(at: pressStart)
        let release = press.release(at: pressTime(0.2))
        #expect(release == .tap, "a quick release is a tap")
        let consumed = press.consumeButtonAction()
        #expect(consumed, "the button action still fires the tap")
    }

    @Test func testLongPressFiresOnceAndSwallowsTheRelease() {
        var press = AgentChipPress(threshold: pressThreshold)
        _ = press.press(at: pressStart)

        let fired = press.thresholdReached(at: pressTime(0.5))
        #expect(fired == .longPress, "the threshold fires the long press")
        let again = press.thresholdReached(at: pressTime(0.6))
        #expect(again == .none, "a second timer fire is ignored")

        let release = press.release(at: pressTime(0.7))
        #expect(release == .swallowedRelease, "the release belongs to the long press")
        let firstAction = press.consumeButtonAction()
        #expect(firstAction == false, "the button action must not tap")
        let secondAction = press.consumeButtonAction()
        #expect(secondAction, "the swallow is consumed after one action")
    }

    @Test func testDelayedTimerDoesNotTurnALongHoldIntoATap() {
        var press = AgentChipPress(threshold: pressThreshold)
        _ = press.press(at: pressStart)

        // The timer never fired; the release duration still decides.
        let release = press.release(at: pressTime(0.9))
        #expect(release == .swallowedRelease, "a long hold is never also a tap")
        let consumed = press.consumeButtonAction()
        #expect(consumed == false)
    }

    @Test func testThresholdAfterReleaseIsIgnored() {
        var press = AgentChipPress(threshold: pressThreshold)
        _ = press.press(at: pressStart)
        let release = press.release(at: pressTime(0.1))
        #expect(release == .tap)

        let late = press.thresholdReached(at: pressTime(0.6))
        #expect(late == .none, "a late timer cannot fire a long press")
        let consumed = press.consumeButtonAction()
        #expect(consumed)
    }

    @Test func testANewPressRearmsTheLongPress() {
        var press = AgentChipPress(threshold: pressThreshold)
        _ = press.press(at: pressStart)
        _ = press.thresholdReached(at: pressTime(0.5))
        _ = press.release(at: pressTime(0.6))
        _ = press.consumeButtonAction()

        _ = press.press(at: pressTime(5))
        let release = press.release(at: pressTime(5.1))
        #expect(release == .tap, "the next press is a normal tap")
        let consumed = press.consumeButtonAction()
        #expect(consumed)
    }

    @Test func testTheLongerInterruptHoldNeedsTheFullDuration() {
        var press = AgentChipPress(threshold: Theme.Timing.agentInterruptHold)
        _ = press.press(at: pressStart)
        let early = press.release(at: pressTime(0.5))
        #expect(early == .tap, "0.5s is only a tap at the interrupt threshold")

        _ = press.press(at: pressTime(2))
        let fired = press.thresholdReached(
            at: pressTime(2 + Theme.Timing.agentInterruptHold))
        #expect(fired == .longPress, "the full 1.2s hold fires the interrupt")
    }

    @Test func testThresholdWithoutAPressDoesNothing() {
        var press = AgentChipPress(threshold: pressThreshold)
        let threshold = press.thresholdReached(at: pressTime(1))
        #expect(threshold == .none)
        let release = press.release(at: pressTime(2))
        #expect(release == .none)
    }
}
