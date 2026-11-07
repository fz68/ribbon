import Foundation
import Testing
@testable import RibbonCore

@MainActor @Suite(.serialized) final class TouchBarChipsTests {
    init() { _ = TestBootstrap.tempRoot }

    // MARK: - rebuildChips: empty list, reuse, count changes

    @Test func testPlanForAnEmptyListIsNoChips() {
        let controller = TouchBarController()
        controller.workspaces = []
        controller.rebuildChips()
        let chips = controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }
        #expect(chips.count == 0, "an empty workspace list yields no chip views")
    }

    @Test func testPlanReusesExistingChipsOnASizeMatch() {
        // Positional reuse: same count means the same ChipView objects survive.
        let controller = TouchBarController()
        let ws = [Workspace(name: "1", isFocused: true, apps: ["Mail"]),
                  Workspace(name: "2", isFocused: false, apps: ["Safari"])]
        controller.workspaces = ws
        controller.rebuildChips()
        let first = controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }
        controller.rebuildChips()
        let second = controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }
        #expect(second.count == 2, "the chip count matches the workspace count")
        #expect(first.first === second.first, "the first chip is reused, not reallocated")
        #expect(first.last === second.last, "the last chip is reused, not reallocated")
    }

    @Test func testPlanShrinksAndGrowsTheCount() {
        let controller = TouchBarController()
        let two = [Workspace(name: "1", isFocused: true, apps: ["Mail"]),
                   Workspace(name: "2", isFocused: false, apps: ["Safari"])]
        controller.workspaces = two
        controller.rebuildChips()
        #expect(controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }.count == 2,
                "two workspaces give two chips")
        let three = two + [Workspace(name: "3", isFocused: false, apps: ["Notes"])]
        controller.workspaces = three
        controller.rebuildChips()
        #expect(controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }.count == 3,
                "a third workspace adds one chip")
        controller.workspaces = [two[0]]
        controller.rebuildChips()
        #expect(controller.leftStack.arrangedSubviews.compactMap { $0 as? ChipView }.count == 1,
                "a shorter list drops to one chip")
    }

    // MARK: - Placeholder chip

    @Test func testPlaceholderChipCarriesNoApps() {
        let controller = TouchBarController()
        let placeholder = controller.makePlaceholderChip()
        #expect(placeholder.attributedTitle.string == "?",
                "the placeholder shows the question-mark glyph as its label")
        #expect(placeholder.image == nil, "the placeholder carries no icon image")
        #expect(placeholder.subviews.count == 0, "the placeholder has no icon subviews")
    }

    // MARK: - Theme.Layout constants

    @Test func testStyleConstantsDriveTheChipGeometry() {
        #expect(Theme.Layout.chipWidth >= Theme.Layout.chipMinWidth,
                "the chip width is at least the minimum")
        #expect(Theme.Layout.iconSize > 0, "the icon size is positive")
        #expect(Theme.Layout.chipFontSize > 0, "the chip font size is positive")
        #expect(Theme.Layout.chipContentTrailingPriority == 999,
                "the chip content trailing priority is 999")
        #expect(Theme.Layout.appLabelTrailingPriority == 999,
                "the app label trailing priority is 999")
    }

    // MARK: - Shutdown idempotence

    @Test func testShutdownIsIdempotent() {
        let controller = TouchBarController()
        controller.shutdown()
        controller.shutdown()
        #expect(controller.didShutdown == true, "the flag is set after shutdown")
        #expect(controller.refreshTimer == nil, "the refresh timer is cleared")
        #expect(controller.clockTimer == nil, "the clock timer is cleared")
        #expect(controller.batteryTimer == nil, "the battery timer is cleared")
    }
}
