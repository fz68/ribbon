import Foundation
import Testing
@testable import RibbonCore

private let cardTime = Date(timeIntervalSince1970: 1_800_000_000)

private func cardTarget(_ requestID: String = "per_1",
                        sessionID: String = "ses_1",
                        shortName: String = "ribbon",
                        position: Int = 1,
                        total: Int = 2) -> AgentCardTarget {
    AgentCardTarget(sessionID: sessionID,
                    requestID: requestID,
                    shortName: shortName,
                    position: position,
                    total: total,
                    directory: "/Users/x/projects/ribbon")
}

@Suite(.serialized) final class AgentCardMachineTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testOpenChooseSubmittedCloses() {
        var machine = AgentCardMachine()
        let target = cardTarget()

        let opened = machine.open(target: target, now: cardTime)
        #expect(opened, "a closed card opens")
        #expect(machine.phase == .open(target, openedAt: cardTime))
        #expect(machine.target == target, "the target is readable while open")

        let locked = machine.choose(decision: .once, now: cardTime.addingTimeInterval(1))
        #expect(locked == target, "choose hands back the locked target")
        #expect(machine.phase == .submitting(target, answer: .permission(.once)))

        let submitted = machine.submitted(now: cardTime.addingTimeInterval(2))
        #expect(submitted, "a success closes the card")
        #expect(machine.phase == .closed)
        #expect(machine.target == nil)
    }

    @Test func testFormTargetLocksFieldKeyAndOption() {
        var machine = AgentCardMachine()
        let target = AgentCardTarget(sessionID: "ses_1",
                                     requestID: "frm_1",
                                     shortName: "ribbon",
                                     position: 1,
                                     total: 1,
                                     directory: "/Users/x/projects/ribbon",
                                     kind: .form(fieldKey: "choice"),
                                     options: [AgentFormOption(value: "go", label: "Go"),
                                               AgentFormOption(value: "stop", label: "Stop")])
        let opened = machine.open(target: target, now: cardTime)
        #expect(opened, "a closed card opens on a form target")
        #expect(machine.target?.isForm == true, "the card knows it answers a form")
        #expect(machine.target?.fieldKey == "choice", "the field key is locked with it")

        let locked = machine.choose(option: "stop", now: cardTime.addingTimeInterval(1))
        #expect(locked == target, "choose hands back the locked form target")
        #expect(machine.phase == .submitting(target, answer: .form(option: "stop")),
                "the option travels with the locked target, not the live queue")

        let second = machine.choose(option: "go", now: cardTime.addingTimeInterval(2))
        #expect(second == nil, "a second option cannot race the first")

        machine.failed(now: cardTime.addingTimeInterval(2), flash: 0.6)
        guard case .failed(let failedTarget, let answer, _) = machine.phase else {
            Issue.record("expected failed, got \(machine.phase)")
            return
        }
        #expect(failedTarget == target, "a failed form reply keeps the locked target")
        #expect(answer == .form(option: "stop"), "and the chosen option")

        let late = machine.submitted(now: cardTime.addingTimeInterval(3))
        #expect(late == false, "a late success while flashing must not close the card")

        machine.recoverFromFlash(now: cardTime.addingTimeInterval(3), flash: 0.6)
        let retry = machine.choose(option: "go", now: cardTime.addingTimeInterval(4))
        #expect(retry == target, "the recovered form card can retry another option")

        let submitted = machine.submitted(now: cardTime.addingTimeInterval(5))
        #expect(submitted, "an accepted form reply closes the card")
        #expect(machine.phase == .closed)
    }

    @Test func testOpenRejectsWhenAlreadyOpen() {
        var machine = AgentCardMachine()
        let first = cardTarget("per_1")
        let second = cardTarget("per_2", position: 2)

        let firstOpened = machine.open(target: first, now: cardTime)
        let secondOpened = machine.open(target: second, now: cardTime.addingTimeInterval(1))
        #expect(firstOpened)
        #expect(secondOpened == false,
                "a second open must not replace the locked request")
        #expect(machine.target == first, "the first target stays locked")
    }

    @Test func testChooseWhileClosedReturnsNil() {
        var machine = AgentCardMachine()
        let locked = machine.choose(decision: .always, now: cardTime)
        #expect(locked == nil)
        #expect(machine.phase == .closed, "nothing changes without a card")
    }

    @Test func testChooseIsIgnoredWhileSubmitting() {
        var machine = AgentCardMachine()
        let target = cardTarget()
        _ = machine.open(target: target, now: cardTime)
        _ = machine.choose(decision: .once, now: cardTime)

        let second = machine.choose(decision: .always, now: cardTime.addingTimeInterval(1))
        #expect(second == nil, "a second decision cannot race the first")
        #expect(machine.phase == .submitting(target, answer: .permission(.once)))
    }

    @Test func testRaceRepliedMatchesByRequestIDOnly() {
        var machine = AgentCardMachine()
        let target = cardTarget("per_1")
        _ = machine.open(target: target, now: cardTime)

        let other = machine.raceReplied(requestID: "per_other")
        #expect(other == false, "another request being answered leaves this card alone")
        #expect(machine.target == target)

        let matching = machine.raceReplied(requestID: "per_1")
        #expect(matching, "the locked request being answered closes the card")
        #expect(machine.phase == .closed)
    }

    @Test func testRaceRepliedClosesSubmittingAndFailed() {
        var submitting = AgentCardMachine()
        _ = submitting.open(target: cardTarget(), now: cardTime)
        _ = submitting.choose(decision: .reject, now: cardTime)
        let closedSubmit = submitting.raceReplied(requestID: "per_1")
        #expect(closedSubmit, "a race during submit closes")
        #expect(submitting.phase == .closed)

        var failed = AgentCardMachine()
        _ = failed.open(target: cardTarget(), now: cardTime)
        _ = failed.choose(decision: .reject, now: cardTime)
        failed.failed(now: cardTime, flash: 0.6)
        let closedFlash = failed.raceReplied(requestID: "per_1")
        #expect(closedFlash, "a race during the flash closes")
        #expect(failed.phase == .closed)
    }

    @Test func testSubmittingNeverExpires() {
        var machine = AgentCardMachine()
        let target = cardTarget()
        _ = machine.open(target: target, now: cardTime)
        _ = machine.choose(decision: .reject, now: cardTime)

        let expired = machine.expire(now: cardTime.addingTimeInterval(1000), timeout: 5)
        #expect(expired == false,
                "a submit in flight waits on the service, not on the user")
        #expect(machine.phase == .submitting(target, answer: .permission(.reject)))
    }

    @Test func testExpireClosesAfterTimeoutNotBefore() {
        var machine = AgentCardMachine()
        let target = cardTarget()
        _ = machine.open(target: target, now: cardTime)

        let early = machine.expire(now: cardTime.addingTimeInterval(4.9), timeout: 5)
        #expect(early == false, "the card survives just under its timeout")
        #expect(machine.phase == .open(target, openedAt: cardTime))

        let onTime = machine.expire(now: cardTime.addingTimeInterval(5), timeout: 5)
        #expect(onTime, "the card closes at its timeout")
        #expect(machine.phase == .closed)
    }

    @Test func testFailedFlashesThenRecoversToOpen() {
        var machine = AgentCardMachine()
        let target = cardTarget()
        _ = machine.open(target: target, now: cardTime)
        _ = machine.choose(decision: .once, now: cardTime.addingTimeInterval(1))

        machine.failed(now: cardTime.addingTimeInterval(2), flash: 0.6)
        guard case .failed(let failedTarget, let answer, let flashUntil) = machine.phase else {
            Issue.record("expected failed, got \(machine.phase)")
            return
        }
        #expect(failedTarget == target, "the failure keeps the locked target")
        #expect(answer == .permission(.once), "the failure keeps the chosen answer")
        #expect(flashUntil == cardTime.addingTimeInterval(2.6))

        machine.recoverFromFlash(now: cardTime.addingTimeInterval(2.5), flash: 0.6)
        guard case .failed = machine.phase else {
            Issue.record("the card recovered before the flash ended")
            return
        }

        machine.recoverFromFlash(now: cardTime.addingTimeInterval(2.6), flash: 0.6)
        #expect(machine.phase == .open(target, openedAt: cardTime.addingTimeInterval(2.6)),
                "the card returns to normal with a fresh window")

        let retry = machine.choose(decision: .always, now: cardTime.addingTimeInterval(3))
        #expect(retry == target, "the recovered card can retry the same request")
    }

    @Test func testFailedCardExpiresWhenTheFlashElapsed() {
        var machine = AgentCardMachine()
        _ = machine.open(target: cardTarget(), now: cardTime)
        _ = machine.choose(decision: .once, now: cardTime)
        machine.failed(now: cardTime.addingTimeInterval(2), flash: 0.6)

        let stillFlashing = machine.expire(now: cardTime.addingTimeInterval(2.5), timeout: 5)
        #expect(stillFlashing == false, "a card still flashing is not timed out")

        let elapsed = machine.expire(now: cardTime.addingTimeInterval(2.6), timeout: 5)
        #expect(elapsed, "a failed card whose flash elapsed can expire")
        #expect(machine.phase == .closed)
    }

    @Test func testFailedOnlyAppliesWhileSubmitting() {
        var machine = AgentCardMachine()
        let target = cardTarget()
        _ = machine.open(target: target, now: cardTime)

        machine.failed(now: cardTime, flash: 0.6)
        #expect(machine.phase == .open(target, openedAt: cardTime),
                "an open card cannot enter the failed phase")

        _ = machine.dismiss(now: cardTime)
        machine.failed(now: cardTime, flash: 0.6)
        #expect(machine.phase == .closed, "a closed card cannot enter the failed phase")
    }

    @Test func testNextIndexAdvancesAndClamps() {
        let first = cardTarget("per_1", position: 1, total: 3)
        let second = cardTarget("per_2", position: 2, total: 3)
        let third = cardTarget("per_3", position: 3, total: 3)
        let triage = [first, second, third]

        #expect(AgentCardMachine.nextIndex(after: "per_1", in: triage) == 1,
                "the skip advances to the next request")
        #expect(AgentCardMachine.nextIndex(after: "per_2", in: triage) == 2)
        #expect(AgentCardMachine.nextIndex(after: "per_3", in: triage) == nil,
                "the last request has nowhere to advance")
        #expect(AgentCardMachine.nextIndex(after: nil, in: triage) == 0,
                "a closed card starts at the head")
        #expect(AgentCardMachine.nextIndex(after: "per_gone", in: triage) == nil,
                "a vanished request is not an advance")
        #expect(AgentCardMachine.nextIndex(after: "per_1", in: [first]) == nil,
                "a single pending has nowhere to advance")
        #expect(AgentCardMachine.nextIndex(after: "per_1", in: []) == nil,
                "an empty queue has nothing to skip to")
    }

    @Test func testDismissReportsWhetherACardWasShowing() {
        var machine = AgentCardMachine()
        let nothingToDismiss = machine.dismiss(now: cardTime)
        #expect(nothingToDismiss == false, "nothing to dismiss when closed")

        _ = machine.open(target: cardTarget(), now: cardTime)
        let dismissedOpen = machine.dismiss(now: cardTime)
        #expect(dismissedOpen, "an open card dismisses")
        #expect(machine.phase == .closed)

        _ = machine.open(target: cardTarget(), now: cardTime)
        _ = machine.choose(decision: .once, now: cardTime)
        let dismissedSubmitting = machine.dismiss(now: cardTime)
        #expect(dismissedSubmitting, "a submitting card dismisses too")
        let lateSuccess = machine.submitted(now: cardTime)
        #expect(lateSuccess == false, "a late success after dismissal is a no-op")
        #expect(machine.phase == .closed)
    }
}
