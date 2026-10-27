import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipLayoutTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testFixedChipWidthFitsTheWidestBuiltInContent() {
        // At 56 pt the insets leave 40 pt: enough for a three-digit workspace
        // number (about 25 pt). Beside a one- or two-digit number one 12 pt app
        // icon still fits; a three-digit number fills the chip.
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        for name in ["1", "10", "99", "100"] {
            let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
            #expect(nameWidth + Theme.Layout.chipInset * 2 <= Theme.Layout.chipWidth,
                    "the workspace number \(name) fits the fixed chip width")
        }
    }
}
