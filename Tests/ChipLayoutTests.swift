import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipLayoutTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testFixedChipWidthFitsTheWidestBuiltInContent() {
        // The widest content a chip draws: the workspace name, the app icons
        // and the chip's own padding on both sides.
        let name = "1"
        let font = NSFont.systemFont(ofSize: Theme.Layout.chipFontSize)
        let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
        let iconCount = CGFloat(AeroSpace.maxAppsPerWorkspace)
        let icons = iconCount * Theme.Layout.iconSize
        // The icons sit next to each other with the stack's own spacing.
        let iconGaps = (iconCount - 1) * Theme.Layout.microSpacing
        let total = nameWidth
            + Theme.Layout.chipLabelSpacing
            + icons
            + iconGaps
            + Theme.Layout.chipInset * 2
        #expect(total <= Theme.Layout.chipWidth,
                "the widest built-in chip content fits the fixed chip width")
    }
}
