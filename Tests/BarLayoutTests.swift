import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class BarLayoutTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testBarLayoutModes() {
        #expect(BarLayout.full.width == Theme.Layout.fullWidth,
                "full keeps the full width")
        #expect(BarLayout.strip.width == Theme.Layout.stripWidth,
                "strip keeps the strip width")

        #expect(!BarLayout.full.hidesMediaCluster, "full shows the media cluster")
        #expect(!BarLayout.full.hidesAppLabel, "full shows the app label")
        #expect(!BarLayout.full.collapsesAppLabel, "full does not collapse the app label")
        #expect(!BarLayout.full.hidesSystemKeys, "full shows the system keys")
        #expect(BarLayout.full.chipRowAnchor == BarLayout.ChipRowAnchor.media,
                "full anchors the chips to the media row")

        #expect(BarLayout.strip.hidesMediaCluster, "strip hides the media cluster")
        #expect(BarLayout.strip.hidesAppLabel, "strip hides the app label")
        #expect(BarLayout.strip.collapsesAppLabel, "strip collapses the app label")
        #expect(BarLayout.strip.hidesSystemKeys, "strip hides the system keys")
        #expect(BarLayout.strip.chipRowAnchor == BarLayout.ChipRowAnchor.container,
                "strip anchors the chips to the container")
    }

    @Test func testBarLayoutInitVisible() {
        #expect(BarLayout(visible: true) == BarLayout.strip,
                "visible maps to the strip layout")
        #expect(BarLayout(visible: false) == BarLayout.full,
                "hidden maps to the full layout")
    }
}
