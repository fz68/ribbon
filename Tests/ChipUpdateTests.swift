import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipUpdateTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testPlanSkipsIdenticalChip() {
        let ws = Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"])
        let plan = ChipUpdate.plan(workspace: ws, displayed: ws, apps: ["Mail", "Safari"],
                                   iconApps: ["Mail", "Safari"], iconGeneration: 3, iconCacheGeneration: 3)
        #expect(plan == .skip, "an unchanged chip at the same cache generation touches nothing")
    }

    @Test func testPlanFirstShowRestyles() {
        let ws = Workspace(name: "1", isFocused: false, apps: ["Slack"])
        let plan = ChipUpdate.plan(workspace: ws, displayed: nil, apps: ["Slack"],
                                   iconApps: [], iconGeneration: 0, iconCacheGeneration: 0)
        #expect(plan == .restyle(reconcileIcons: true),
                "a chip with nothing displayed yet restyles and builds icons")
    }

    @Test func testPlanRestylesAfterGenerationBump() {
        let ws = Workspace(name: "1", isFocused: true, apps: ["Mail"])
        let plan = ChipUpdate.plan(workspace: ws, displayed: ws, apps: ["Mail"],
                                   iconApps: ["Mail"], iconGeneration: 3, iconCacheGeneration: 4)
        #expect(plan == .restyle(reconcileIcons: true),
                "a cache generation bump reconciles icons even when the app list is unchanged")
    }

    @Test func testPlanFocusFlipRestylesWithoutIcons() {
        let old = Workspace(name: "1", isFocused: false, apps: ["Mail"])
        let new = Workspace(name: "1", isFocused: true, apps: ["Mail"])
        let plan = ChipUpdate.plan(workspace: new, displayed: old, apps: ["Mail"],
                                   iconApps: ["Mail"], iconGeneration: 2, iconCacheGeneration: 2)
        #expect(plan == .restyle(reconcileIcons: false),
                "a focus flip restyles border and text without touching icon views")
    }

    @Test func testPlanNameChangeRestylesWithoutIcons() {
        let old = Workspace(name: "1", isFocused: false, apps: ["Mail"])
        let new = Workspace(name: "2", isFocused: false, apps: ["Mail"])
        let plan = ChipUpdate.plan(workspace: new, displayed: old, apps: ["Mail"],
                                   iconApps: ["Mail"], iconGeneration: 2, iconCacheGeneration: 2)
        #expect(plan == .restyle(reconcileIcons: false),
                "a name change restyles without rebuilding icon views")
    }

    @Test func testPlanAppListChangeReconcilesIcons() {
        let old = Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"])
        let new = Workspace(name: "1", isFocused: true, apps: ["Safari", "Mail"])
        let plan = ChipUpdate.plan(workspace: new, displayed: old, apps: ["Safari", "Mail"],
                                   iconApps: ["Mail", "Safari"], iconGeneration: 2, iconCacheGeneration: 2)
        #expect(plan == .restyle(reconcileIcons: true),
                "an app reorder reconciles icon views")
    }

    @Test func testPlanAppsBeyondPrefixRestyleWithoutIcons() {
        let old = Workspace(name: "1", isFocused: true, apps: ["A", "B", "C", "D"])
        let new = Workspace(name: "1", isFocused: true, apps: ["A", "B", "C", "E"])
        let plan = ChipUpdate.plan(workspace: new, displayed: old, apps: ["A", "B", "C"],
                                   iconApps: ["A", "B", "C"], iconGeneration: 1, iconCacheGeneration: 1)
        #expect(plan == .restyle(reconcileIcons: false),
                "a change past the icon prefix restyles but does not rebuild icons")
    }

    @Test func testIconCountFitsTwoIconsForAShortLabel() {
        #expect(ChipUpdate.iconCount(labelWidth: 8, chipWidth: 56, maxIcons: 3) == 2,
                "free = 56 - 16 - 8 = 32, two icons need 6 + 24 + 2 = 32, three need 46")
    }

    @Test func testIconCountFitsOneIconForATwoDigitLabel() {
        #expect(ChipUpdate.iconCount(labelWidth: 16, chipWidth: 56, maxIcons: 3) == 1,
                "free = 56 - 16 - 16 = 24, one icon needs 18, two need 32")
    }

    @Test func testIconCountRespectsThePerWorkspaceCap() {
        #expect(ChipUpdate.iconCount(labelWidth: 8, chipWidth: 56, maxIcons: 1) == 1,
                "a cap of one never asks for a second icon")
    }

    @Test func testIconCountZeroCapShowsNone() {
        #expect(ChipUpdate.iconCount(labelWidth: 8, chipWidth: 56, maxIcons: 0) == 0,
                "a cap of zero shows no icons at all")
    }

    @Test func testIconCountLongLabelShowsNone() {
        #expect(ChipUpdate.iconCount(labelWidth: 100, chipWidth: 56, maxIcons: 3) == 0,
                "free = 56 - 16 - 100 = -60, not even one icon fits")
    }

    @Test func testIconCountEmptyLabelStopsAtTwoOfThree() {
        #expect(ChipUpdate.iconCount(labelWidth: 0, chipWidth: 56, maxIcons: 3) == 2,
                "free = 56 - 16 - 0 = 40, two icons need 32 but three need 46")
    }

    @Test func testColorIndexIsStableAndInRange() {
        let names = ["1", "2", "web", "code", "media", "杂项"]
        // Pinned djb2 results; they assume the current 12-entry palette and must
        // be recomputed if chipRainbow changes length.
        let pinned = [10, 11, 11, 8, 1, 0]
        let indices = names.map { ChipUpdate.colorIndex(forName: $0) }
        for (name, index) in zip(names, pinned) {
            #expect(ChipUpdate.colorIndex(forName: name) == index,
                    "the same name hashes to the same colour index in every process")
        }
        for index in indices {
            #expect((0..<Theme.chipRainbow.count).contains(index),
                    "the colour index lands inside the rainbow palette")
        }
        #expect(Set(indices).count >= 2,
                "different names spread across the palette instead of all colliding")
    }
}
