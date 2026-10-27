import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class BarSlotsTests {
    init() { _ = TestBootstrap.tempRoot }

    /// The font the right cluster draws its labels with.
    private func labelFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium)
    }

    @Test func testBatteryTextFitsTheBatterySlot() {
        let text = "100%"
        let size = (text as NSString).size(withAttributes: [.font: labelFont()])
        #expect(size.width <= Theme.Layout.batterySlotWidth,
                "the battery percentage fits the fixed battery slot")
    }
}
