import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipUpdateTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testDisplayNameMapsTheTenthWorkspaceToZero() {
        #expect(ChipUpdate.displayName(for: "10") == "0",
                "the 10th workspace reads 0, like the 0 key that reaches it")
        #expect(ChipUpdate.displayName(for: "1") == "1", "a single digit is unchanged")
        #expect(ChipUpdate.displayName(for: "9") == "9", "the 9th workspace is unchanged")
        #expect(ChipUpdate.displayName(for: "main") == "main",
                "a non-numeric name is untouched")
    }

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

    @Test func testIconCountThatFitsFitsWithinDefaultChip() {
        // 72 - 16 inset - 15.6 label - 6 gap = 34.4 pt for icons: two 12 pt
        // icons plus one 2 pt gap is 26, three would need 40.
        #expect(ChipUpdate.iconCountThatFits(chipWidth: 72, nameWidth: 15.6, iconCount: 3) == 2,
                "a full-width chip shows two of three icons")
    }

    @Test func testIconCountThatFitsDropsIconsInCompressedChip() {
        // 55 - 16 - 15.6 - 6 = 17.4 pt: only one 12 pt icon fits.
        #expect(ChipUpdate.iconCountThatFits(chipWidth: 55, nameWidth: 15.6, iconCount: 3) == 1,
                "a compressed chip keeps only the first icon")
    }

    @Test func testIconCountThatFitsKeepsNoIconWhenNameFillsChip() {
        // 72 - 16 - 50 - 6 = 0 pt: not even one icon fits beside a wide name.
        #expect(ChipUpdate.iconCountThatFits(chipWidth: 72, nameWidth: 50, iconCount: 3) == 0,
                "a name that fills the chip leaves no room for icons")
    }

    @Test func testIconCountThatFitsHandlesNoIcons() {
        #expect(ChipUpdate.iconCountThatFits(chipWidth: 72, nameWidth: 15.6, iconCount: 0) == 0,
                "a chip without icons reports none")
    }

    @Test func testIconCountThatFitsNeverExceedsIconCount() {
        for count in 0...5 {
            for width in stride(from: CGFloat(40), through: 200, by: 5) {
                let visible = ChipUpdate.iconCountThatFits(chipWidth: width, nameWidth: 15.6, iconCount: count)
                #expect((0...count).contains(visible),
                        "the visible count stays within the icons the chip actually has")
            }
        }
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
