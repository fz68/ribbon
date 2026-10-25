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

    @Test func testChipWidthClampsLow() {
        #expect(ChipUpdate.chipWidth(forContentWidth: 10) == Theme.Layout.chipMinWidth,
                "narrow content clamps to the minimum chip width")
        #expect(ChipUpdate.chipWidth(forContentWidth: 24) == Theme.Layout.chipMinWidth,
                "content exactly at min minus padding lands on the minimum")
    }

    @Test func testChipWidthClampsHigh() {
        #expect(ChipUpdate.chipWidth(forContentWidth: 1000) == Theme.Layout.chipMaxWidth,
                "wide content clamps to the maximum chip width")
    }

    @Test func testChipWidthAddsPaddingInBetween() {
        #expect(ChipUpdate.chipWidth(forContentWidth: 30) == 46,
                "mid-range content gets the padding added (30 + 16)")
    }
}
