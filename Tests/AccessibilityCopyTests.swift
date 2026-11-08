import Cocoa
import Testing
@testable import RibbonCore

/// The AX strings that are pure data, plus the few view properties that can be
/// read back without a Touch Bar.
///
/// Each sentence here is a contract: a reworded label is otherwise only caught
/// by a human listening to VoiceOver, so the mapping is pinned where it can be
/// asserted. The announcement sites are deliberately not tested: they need a
/// live assistive client, and a unit test cannot observe a posted notification.
@MainActor @Suite(.serialized) final class AccessibilityCopyTests {
    init() { _ = TestBootstrap.tempRoot }

    // MARK: - Agent chip

    @Test func testAgentChipValueCoversTheQuietStates() {
        #expect(AgentChipState.off.accessibilityValue == "hidden",
                "a collapsed chip is hidden, not busy")
        #expect(AgentChipState.idle.accessibilityValue == "idle",
                "idle says it is present but quiet")
        #expect(AgentChipState.done.accessibilityValue == "finished",
                "the green done flash reads as finished")
    }

    @Test func testAgentChipValueCountsSessionsAndApprovals() {
        #expect(AgentChipState.busy(count: 1).accessibilityValue == "1 session busy",
                "one busy session is singular")
        #expect(AgentChipState.busy(count: 3).accessibilityValue == "3 sessions busy",
                "several busy sessions are plural")
        #expect(AgentChipState.awaiting(count: 1).accessibilityValue == "1 approval waiting",
                "one waiting approval is singular, like the busy wording")
        #expect(AgentChipState.awaiting(count: 2).accessibilityValue == "2 approvals waiting")
    }

    @Test func testChipVisualCarriesTheValueItPaints() {
        // The chip is one stop, so the value comes from the same state that
        // chooses the fill and the number.
        for state in [AgentChipState.off, .idle, .busy(count: 2), .awaiting(count: 1), .done] {
            #expect(AgentChipVisual.visual(for: state).accessibilityValue == state.accessibilityValue,
                    "the visual and the spoken value cannot disagree")
        }
    }

    // MARK: - Approval card

    @Test func testCardIdentitySpellsOutTheQueuePosition() {
        let target = AgentCardTarget(sessionID: "ses_1",
                                     requestID: "per_1",
                                     shortName: "ribbon",
                                     position: 2,
                                     total: 3,
                                     directory: "/x/ribbon")
        #expect(target.accessibilityIdentity == "ribbon, request 2 of 3",
                "the identity cell spells out what the drawn \"2/3\" abbreviates")
    }

    // MARK: - Media transport

    @Test func testMediaLabelFollowsTheDrawnSymbol() {
        #expect(TouchBarController.mediaPlayPauseLabel(playing: true) == "Pause",
                "the pause glyph is drawn while playing, and activating pauses")
        #expect(TouchBarController.mediaPlayPauseLabel(playing: false) == "Play",
                "the play glyph is drawn while stopped, and activating plays")
        #expect(TouchBarController.mediaPlayPauseLabel(playing: nil) == "Play / pause",
                "the neutral glyph keeps the general label")
    }

    @Test func testMediaButtonsSayThereIsNoSession() {
        let controller = TouchBarController()
        controller.setMediaIdle(true)
        #expect(controller.mediaPrevButton.accessibilityHelp() == "No media session")
        #expect(controller.mediaPlayPauseButton.accessibilityHelp() == "No media session")
        #expect(controller.mediaNextButton.accessibilityHelp() == "No media session")
        controller.setMediaIdle(false)
        #expect(controller.mediaPlayPauseButton.accessibilityHelp() == nil,
                "a live session clears the help again")
    }

    // MARK: - Battery

    @Test func testBatteryLabelRestoresTheUnitAndTheBolt() {
        #expect(TouchBarController.batteryAccessibilityLabel(BatteryState(percent: 87, charging: false))
                == "Battery 87 percent")
        #expect(TouchBarController.batteryAccessibilityLabel(BatteryState(percent: 87, charging: true))
                == "Battery 87 percent, charging",
                "the bolt's meaning is spoken, not drawn only")
        #expect(TouchBarController.batteryAccessibilityLabel(BatteryState(percent: 100, charging: false))
                == "Battery full",
                "the drawn \"F\" is a full battery")
        #expect(TouchBarController.batteryAccessibilityLabel(BatteryState(percent: 100, charging: true))
                == "Battery full, charging",
                "\"F\" is drawn while charging too")
        #expect(TouchBarController.batteryAccessibilityLabel(nil) == "Battery level unknown",
                "the drawn \"--%\" is an unknown reading")
    }

    // MARK: - Workspace chips

    @Test func testWorkspaceChipCarriesTheDrawnNameAndFocusState() throws {
        let controller = TouchBarController()
        controller.workspaces = [Workspace(name: "10", isFocused: true, apps: [])]
        controller.rebuildChips()
        let chip = try #require(controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }.first)
        let button = try #require(chip.subviews.compactMap { $0 as? ChipTapButton }.first)
        #expect(button.accessibilityLabel() == "0",
                "the tenth workspace reads the number it draws")
        #expect(button.isAccessibilitySelected(), "the focused chip reports itself selected")
        #expect(button.accessibilityValue() as? String == "focused")
    }

    @Test func testUnfocusedChipHasNoValue() throws {
        let controller = TouchBarController()
        controller.workspaces = [Workspace(name: "2", isFocused: false, apps: [])]
        controller.rebuildChips()
        let chip = try #require(controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }.first)
        let button = try #require(chip.subviews.compactMap { $0 as? ChipTapButton }.first)
        #expect(button.accessibilityLabel() == "2", "an ordinary workspace keeps its name")
        #expect(button.isAccessibilitySelected() == false)
        #expect(button.accessibilityValue() == nil, "only a focused chip carries a value")
    }

    @Test func testPlaceholderChipNamesItselfAsTheRefresh() {
        let controller = TouchBarController()
        let placeholder = controller.makePlaceholderChip()
        #expect(placeholder.accessibilityLabel() == "Workspaces unavailable. Activate to refresh.",
                "the \"?\" glyph alone says nothing out loud")
    }
}
