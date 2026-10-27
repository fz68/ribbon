import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ChipLayoutTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testFixedChipWidthFitsTheWidestBuiltInContent() {
        // At 40 pt the insets leave 24 pt: enough for a two-digit workspace
        // number and nothing else. A three-digit name (24.9 pt) truncates, and an
        // app icon (12 pt) never fits, which is why chips show only the number.
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        for name in ["1", "10", "99"] {
            let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
            #expect(nameWidth + Theme.Layout.chipInset * 2 <= Theme.Layout.chipWidth,
                    "the workspace number \(name) fits the fixed chip width")
        }
    }
}
