import Cocoa

/// Builds the SF Symbol images the bar uses.
enum SymbolImage {
    /// - Parameters:
    ///   - symbol: the SF Symbol name.
    ///   - accessibility: the accessibility description of the image.
    ///   - logContext: used in the "SF Symbol unavailable" log line so the
    ///     three original messages keep their distinct text.
    static func make(_ symbol: String, accessibility: String, logContext: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) else {
            log("SF Symbol unavailable: \(symbol) (\(logContext))")
            return nil
        }
        return image
    }

    /// True when the system provides the symbol. Probing is silent, unlike
    /// `make`, so the optional Control Strip symbols can be listed at launch
    /// without logging every candidate that is unavailable.
    static func exists(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) != nil
    }
}
