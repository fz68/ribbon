import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class SymbolImageTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testSymbolImageMakeAndExists() {
        let symbol = "square.grid.2x2"
        #expect(SymbolImage.make(symbol, accessibility: "Grid", logContext: "test") != nil,
                "a real SF Symbol builds an image")
        #expect(SymbolImage.exists(symbol),
                "a real SF Symbol is reported as available")
    }

    @Test func testSymbolImageBogusName() {
        let symbol = "definitely.not.a.symbol"
        #expect(SymbolImage.make(symbol, accessibility: "Bogus", logContext: "test") == nil,
                "a bogus SF Symbol name builds no image")
        #expect(SymbolImage.exists(symbol) == false,
                "a bogus SF Symbol name is not reported as available")
    }
}
