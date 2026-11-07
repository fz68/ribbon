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
}
