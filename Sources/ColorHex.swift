import Cocoa

extension NSColor {
    /// Builds a colour from a "#RRGGBB" string. Returns nil for malformed input.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }

    /// The "#RRGGBB" form of the colour, used in the log.
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(round(redComponent * 255)),
               Int(round(greenComponent * 255)),
               Int(round(blueComponent * 255)))
    }
}
