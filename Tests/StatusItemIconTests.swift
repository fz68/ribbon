import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class StatusItemIconTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testStatusItemIconResourceIsReachable() {
        let url = StatusItemIcon.resourceURL()
        #expect(url != nil, "the menu bar artwork is resolved")
        #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                "the resolved artwork exists on disk")
    }

    @Test func testStatusItemIconIsTemplate() {
        #expect(StatusItemIcon.image?.isTemplate == true,
                "the menu bar icon is a template image")
        #expect(StatusItemIcon.image?.size == StatusItemIcon.pointSize,
                "the menu bar icon is scaled to the point size")
        #expect(StatusItemIcon.image?.accessibilityDescription == "Ribbon",
                "the menu bar icon carries its accessibility description")
    }
}
