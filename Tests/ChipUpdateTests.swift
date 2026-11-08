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

    @Test(arguments: planCases)
    func testPlan(_ testCase: PlanCase) {
        let plan = ChipUpdate.plan(workspace: testCase.workspace,
                                   displayed: testCase.displayed,
                                   apps: testCase.apps,
                                   iconApps: testCase.iconApps,
                                   iconGeneration: testCase.iconGeneration,
                                   iconCacheGeneration: testCase.iconCacheGeneration)
        #expect(plan == testCase.expected, "\(testCase.testDescription)")
    }

    @Test(arguments: iconCountCases)
    func testIconCountThatFits(_ testCase: IconCountCase) {
        let visible = ChipUpdate.iconCountThatFits(chipWidth: testCase.chipWidth,
                                                   nameWidth: testCase.nameWidth,
                                                   iconCount: testCase.iconCount)
        #expect(visible == testCase.expected, "\(testCase.testDescription)")
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

/// One `ChipUpdate.plan` scenario: the chip's inputs and the plan it must return.
///
/// `testDescription` carries the original test's intent into the failure output,
/// which would otherwise only say "case 4 of 7".
struct PlanCase: Sendable, CustomTestStringConvertible {
    let workspace: Workspace
    let displayed: Workspace?
    let apps: [String]
    let iconApps: [String]
    let iconGeneration: Int
    let iconCacheGeneration: Int
    let expected: ChipUpdate.Plan
    let testDescription: String
}

private let planCases: [PlanCase] = [
    PlanCase(workspace: Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"]),
             displayed: Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"]),
             apps: ["Mail", "Safari"],
             iconApps: ["Mail", "Safari"],
             iconGeneration: 3,
             iconCacheGeneration: 3,
             expected: .skip,
             testDescription: "an unchanged chip at the same cache generation touches nothing"),
    PlanCase(workspace: Workspace(name: "1", isFocused: false, apps: ["Slack"]),
             displayed: nil,
             apps: ["Slack"],
             iconApps: [],
             iconGeneration: 0,
             iconCacheGeneration: 0,
             expected: .restyle(reconcileIcons: true),
             testDescription: "a chip with nothing displayed yet restyles and builds icons"),
    PlanCase(workspace: Workspace(name: "1", isFocused: true, apps: ["Mail"]),
             displayed: Workspace(name: "1", isFocused: true, apps: ["Mail"]),
             apps: ["Mail"],
             iconApps: ["Mail"],
             iconGeneration: 3,
             iconCacheGeneration: 4,
             expected: .restyle(reconcileIcons: true),
             testDescription: "a cache generation bump reconciles icons even when the app list is unchanged"),
    PlanCase(workspace: Workspace(name: "1", isFocused: true, apps: ["Mail"]),
             displayed: Workspace(name: "1", isFocused: false, apps: ["Mail"]),
             apps: ["Mail"],
             iconApps: ["Mail"],
             iconGeneration: 2,
             iconCacheGeneration: 2,
             expected: .restyle(reconcileIcons: false),
             testDescription: "a focus flip restyles border and text without touching icon views"),
    PlanCase(workspace: Workspace(name: "2", isFocused: false, apps: ["Mail"]),
             displayed: Workspace(name: "1", isFocused: false, apps: ["Mail"]),
             apps: ["Mail"],
             iconApps: ["Mail"],
             iconGeneration: 2,
             iconCacheGeneration: 2,
             expected: .restyle(reconcileIcons: false),
             testDescription: "a name change restyles without rebuilding icon views"),
    PlanCase(workspace: Workspace(name: "1", isFocused: true, apps: ["Safari", "Mail"]),
             displayed: Workspace(name: "1", isFocused: true, apps: ["Mail", "Safari"]),
             apps: ["Safari", "Mail"],
             iconApps: ["Mail", "Safari"],
             iconGeneration: 2,
             iconCacheGeneration: 2,
             expected: .restyle(reconcileIcons: true),
             testDescription: "an app reorder reconciles icon views"),
    PlanCase(workspace: Workspace(name: "1", isFocused: true, apps: ["A", "B", "C", "E"]),
             displayed: Workspace(name: "1", isFocused: true, apps: ["A", "B", "C", "D"]),
             apps: ["A", "B", "C"],
             iconApps: ["A", "B", "C"],
             iconGeneration: 1,
             iconCacheGeneration: 1,
             expected: .restyle(reconcileIcons: false),
             testDescription: "a change past the icon prefix restyles but does not rebuild icons"),
]

/// One `ChipUpdate.iconCountThatFits` scenario: the chip geometry and the icon
/// count it keeps. `testDescription` keeps the original test's intent in the
/// failure output.
struct IconCountCase: Sendable, CustomTestStringConvertible {
    let chipWidth: CGFloat
    let nameWidth: CGFloat
    let iconCount: Int
    let expected: Int
    let testDescription: String
}

private let iconCountCases: [IconCountCase] = [
    // 72 - 16 inset - 15.6 label - 6 gap = 34.4 pt for icons: two 12 pt
    // icons plus one 2 pt gap is 26, three would need 40.
    IconCountCase(chipWidth: 72, nameWidth: 15.6, iconCount: 3, expected: 2,
                  testDescription: "a full-width chip shows two of three icons"),
    // 55 - 16 - 15.6 - 6 = 17.4 pt: only one 12 pt icon fits.
    IconCountCase(chipWidth: 55, nameWidth: 15.6, iconCount: 3, expected: 1,
                  testDescription: "a compressed chip keeps only the first icon"),
    // 72 - 16 - 50 - 6 = 0 pt: not even one icon fits beside a wide name.
    IconCountCase(chipWidth: 72, nameWidth: 50, iconCount: 3, expected: 0,
                  testDescription: "a name that fills the chip leaves no room for icons"),
    IconCountCase(chipWidth: 72, nameWidth: 15.6, iconCount: 0, expected: 0,
                  testDescription: "a chip without icons reports none"),
]
