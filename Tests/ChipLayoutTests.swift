import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipLayoutTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testFixedChipWidthFitsTheWidestBuiltInContent() {
        // At 50 pt the insets leave 34 pt: enough for a three-digit workspace
        // number, a three-digit name (24.9 pt) fits too, and one 12 pt app icon
        // still fits beside a single-digit number.
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        for name in ["1", "10", "99", "100"] {
            let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
            #expect(nameWidth + Theme.Layout.chipInset * 2 <= Theme.Layout.chipWidth,
                    "the workspace number \(name) fits the fixed chip width")
        }
    }
}
