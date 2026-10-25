import Cocoa
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ColorHexTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testNSColorHex() {
        guard let color = NSColor(hex: "#1122FF") else {
            #expect(Bool(false), "a six digit hex with a hash should parse")
            return
        }
        #expect(abs(color.redComponent - CGFloat(0x11) / 255.0) < 0.001,
                "red decodes the 0x11 channel")
        #expect(abs(color.greenComponent - CGFloat(0x22) / 255.0) < 0.001,
                "green decodes the 0x22 channel")
        #expect(abs(color.blueComponent - CGFloat(0xFF) / 255.0) < 0.001,
                "blue decodes the 0xFF channel")
        #expect(abs(color.alphaComponent - 1) < 0.001,
                "alpha defaults to opaque")

        guard let bare = NSColor(hex: "1122FF") else {
            #expect(Bool(false), "a six digit hex without a hash should parse")
            return
        }
        #expect(abs(bare.blueComponent - CGFloat(0xFF) / 255.0) < 0.001,
                "the hash is optional")

        #expect(NSColor(hex: "  #1122FF\n") != nil,
                "surrounding whitespace is trimmed")
    }

    @Test func testNSColorHexMalformed() {
        #expect(NSColor(hex: "") == nil, "an empty string does not parse")
        #expect(NSColor(hex: "#") == nil, "a bare hash does not parse")
        #expect(NSColor(hex: "12345") == nil, "five hex digits do not parse")
        #expect(NSColor(hex: "1234567") == nil, "seven hex digits do not parse")
        #expect(NSColor(hex: "GGGGGG") == nil, "non-hex digits do not parse")
        #expect(NSColor(hex: "#11 2FF") == nil, "an inner space does not parse")
        #expect(NSColor(hex: "  ") == nil, "whitespace only does not parse")
    }

    @Test func testHexStringRoundTrip() {
        #expect(NSColor(hex: "#3FA62B")!.hexString == "#3FA62B",
                "a colour round-trips through its hex string")
        #expect(NSColor(hex: "#000000")!.hexString == "#000000",
                "black round-trips through its hex string")
        #expect(NSColor(hex: "#FFFFFF")!.hexString == "#FFFFFF",
                "white round-trips through its hex string")
    }

    @Test func testNSColorArgb() {
        let color = NSColor(argb: 0x80112233)
        #expect(abs(color.alphaComponent - CGFloat(0x80) / 255.0) < 0.001,
                "alpha decodes the high byte")
        #expect(abs(color.redComponent - CGFloat(0x11) / 255.0) < 0.001,
                "red decodes the 0x11 channel")
        #expect(abs(color.greenComponent - CGFloat(0x22) / 255.0) < 0.001,
                "green decodes the 0x22 channel")
        #expect(abs(color.blueComponent - CGFloat(0x33) / 255.0) < 0.001,
                "blue decodes the 0x33 channel")
        #expect(color.hexString == "#112233",
                "the hex string ignores the alpha byte")
    }
}
