import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class BarSlotsTests {
    init() { _ = TestBootstrap.tempRoot }

    /// The font the right cluster draws its labels with.
    private func labelFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium)
    }

    /// The label strings applyBattery can draw without a bolt: the widest
    /// percentage, "F" at full charge and the unknown-status fallback.
    @Test func testBatteryLabelsFitTheBatterySlot() {
        for text in ["99%", "F", "--%"] {
            let size = (text as NSString).size(withAttributes: [.font: labelFont()])
            #expect(size.width <= Theme.Layout.batterySlotWidth,
                    "the battery label \(text) fits the fixed battery slot")
        }
    }

    /// While charging the "%" is replaced by a trailing bolt and a full battery
    /// shows "F", so the widest stack content is a two-digit number ("99"), the
    /// gap and the icon.
    @Test func testChargingBatteryContentFitsTheBatterySlot() {
        let number = ("99" as NSString).size(withAttributes: [.font: labelFont()]).width
        let content = number + Theme.Layout.microSpacing + Theme.Layout.iconSize
        #expect(content <= Theme.Layout.batterySlotWidth,
                "the two-digit number plus the charging bolt fit the fixed battery slot")
    }
}
