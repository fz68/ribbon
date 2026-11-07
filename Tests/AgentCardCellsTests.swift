import Foundation
import Testing
@testable import RibbonCore

private func permissionTarget() -> AgentCardTarget {
    AgentCardTarget(sessionID: "ses_1",
                    requestID: "per_1",
                    shortName: "ribbon",
                    position: 1,
                    total: 1,
                    directory: "/x/ribbon")
}

private func formTarget(_ options: [AgentFormOption]) -> AgentCardTarget {
    AgentCardTarget(sessionID: "ses_1",
                    requestID: "frm_1",
                    shortName: "ribbon",
                    position: 1,
                    total: 1,
                    directory: "/x/ribbon",
                    kind: .form(fieldKey: "choice"),
                    options: options)
}

@Suite(.serialized) final class AgentCardCellsTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testPermissionShowsTheThreeDecisions() {
        let cells = AgentCardActionCells.cells(for: permissionTarget())
        #expect(cells.titles == ["允许", "总是", "拒绝"],
                "a permission card is unchanged by the form support")
        #expect(cells.count == 3, "all three cells are shown")
    }

    @Test func testFormShowsOptionLabelsAndHidesSurplusCells() {
        let two = AgentCardActionCells.cells(for: formTarget([
            AgentFormOption(value: "go", label: "Go"),
            AgentFormOption(value: "stop", label: "Stop"),
        ]))
        #expect(two.titles == ["Go", "Stop", ""], "labels fill the action cells")
        #expect(two.count == 2, "a two-option form uses two cells and hides the third")

        let three = AgentCardActionCells.cells(for: formTarget([
            AgentFormOption(value: "a", label: "First"),
            AgentFormOption(value: "b", label: "Second"),
            AgentFormOption(value: "c", label: "Third"),
        ]))
        #expect(three.titles == ["First", "Second", "Third"])
        #expect(three.count == 3)
    }

    @Test func testEmptyLabelFallsBackToTheValue() {
        let cells = AgentCardActionCells.cells(for: formTarget([
            AgentFormOption(value: "go", label: ""),
            AgentFormOption(value: "stop", label: "Stop"),
        ]))
        #expect(cells.titles[0] == "go", "a label-less option shows its value")
        #expect(cells.titles[1] == "Stop", "a labelled option keeps its label")
    }

    @Test func testExtraOptionsCannotWidenTheCard() {
        let cells = AgentCardActionCells.cells(for: formTarget([
            AgentFormOption(value: "a", label: "A"),
            AgentFormOption(value: "b", label: "B"),
            AgentFormOption(value: "c", label: "C"),
            AgentFormOption(value: "d", label: "D"),
        ]))
        #expect(cells.count == 3, "the card has exactly three action cells")
        #expect(cells.titles == ["A", "B", "C"], "surplus options are dropped")
    }
}
