import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class AgentChipVisualTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testOffCollapsesTheChip() {
        let visual = AgentChipVisual.visual(for: .off)
        #expect(visual.text.isEmpty, "off shows no count")
        #expect(visual.showsDot == false, "off shows no dot")
        #expect(visual.pulses == false && visual.hairline == false, "off animates nothing")
    }

    @Test func testIdleIsAHollowDot() {
        let visual = AgentChipVisual.visual(for: .idle)
        #expect(visual.showsDot == true, "idle is marked by the hollow dot")
        #expect(visual.text.isEmpty, "idle has no count")
        #expect(visual.fill == Theme.controlBackground, "idle keeps the neutral fill")
        #expect(visual.border == Theme.placeholderTint, "idle uses the dim outline")
        #expect(visual.pulses == false && visual.hairline == false, "idle is still")
    }

    @Test func testBusyShowsTheCountAndHairline() {
        let visual = AgentChipVisual.visual(for: .busy(count: 3))
        #expect(visual.text == "3", "busy shows the session count")
        #expect(visual.fill == Theme.controlBackground, "busy does not flood the fill")
        #expect(visual.border == Theme.agentBusyBorder, "busy uses the cyan border")
        #expect(visual.textColor == Theme.agentBusyBorder, "busy text matches the border")
        #expect(visual.border != AgentChipVisual.visual(for: .done).fill,
                "busy must not read as the done green")
        #expect(visual.hairline == true, "busy draws the progress hairline")
        #expect(visual.pulses == false, "busy does not pulse")
        #expect(visual.showsDot == false, "busy hides the idle dot")
    }

    @Test func testAwaitingIsAmberAndPulses() {
        let visual = AgentChipVisual.visual(for: .awaiting(count: 2))
        #expect(visual.text == "!2", "awaiting shows a bang and the count")
        #expect(visual.fill == Theme.agentWaitFill, "awaiting fills with amber")
        #expect(visual.border == Theme.agentWaitBorder, "awaiting uses the amber border")
        #expect(visual.textColor == Theme.focusedChipText,
                "dark text stays legible on amber")
        #expect(visual.pulses == true, "awaiting breathes")
        #expect(visual.hairline == false, "awaiting has no hairline")
    }

    @Test func testDoneIsGreen() {
        let visual = AgentChipVisual.visual(for: .done)
        #expect(visual.fill == Theme.agentDoneFill, "done fills green")
        #expect(visual.border == Theme.agentDoneFill, "done's border matches its fill")
        #expect(visual.text.isEmpty, "done shows no count")
        #expect(visual.pulses == false && visual.hairline == false, "done is still")
    }

    @Test func testCountsAreCarriedIntoTheText() {
        #expect(AgentChipVisual.visual(for: .busy(count: 1)).text == "1")
        #expect(AgentChipVisual.visual(for: .busy(count: 12)).text == "12")
        #expect(AgentChipVisual.visual(for: .awaiting(count: 1)).text == "!1")
        #expect(AgentChipVisual.visual(for: .awaiting(count: 9)).text == "!9")
    }

    // MARK: - hairlinePhase: the busy sweep, and its Reduce Motion still frame

    /// Mirrors the private `AgentChipView.hairlinePeriod`, which stays private
    /// because it is not part of any other contract.
    private let hairlinePeriod: TimeInterval = 2.4

    @Test func testReduceMotionHoldsTheHairlineAtFullWidth() {
        // Any elapsed value: under Reduce Motion the line is a static, complete
        // bar, never a frozen fragment at the shortest width.
        for elapsed in [0.0, 0.6, 1.2, 2.4, 60.0] as [TimeInterval] {
            let phase = AgentChipView.hairlinePhase(elapsed: elapsed,
                                                    reducesMotion: true)
            #expect(phase == 1,
                    "Reduce Motion must settle the line at full width (elapsed \(elapsed))")
        }
    }

    @Test func testTheHairlineSweepsAsATriangleWave() {
        #expect(AgentChipView.hairlinePhase(elapsed: 0, reducesMotion: false) == 0,
                "the sweep starts at the shortest position")
        #expect(AgentChipView.hairlinePhase(elapsed: hairlinePeriod / 2,
                                           reducesMotion: false) == 1,
                "half a period is the widest position")
        #expect(AgentChipView.hairlinePhase(elapsed: hairlinePeriod,
                                           reducesMotion: false) == 0,
                "a full period returns to the shortest position")
    }

    @Test func testTheHairlinePhaseStaysWithinTheSweepRange() {
        let steps = 48
        for step in 0...steps {
            let elapsed = hairlinePeriod * Double(step) / Double(steps)
            let phase = AgentChipView.hairlinePhase(elapsed: elapsed,
                                                    reducesMotion: false)
            #expect(phase >= 0 && phase <= 1,
                    "phase \(phase) at step \(step) stays within 0...1")
        }
    }
}
