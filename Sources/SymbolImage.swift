import Cocoa

/// Builds the SF Symbol images the bar uses.
///
/// Resolved images are cached so the bar does not re-resolve the same SF Symbol
/// on every Control Strip mode or media state change. The cache is read and
/// written from the main thread only: every call site builds its views on main.
enum SymbolImage {
    /// Resolved images keyed by "<symbol>|<accessibility>". The symbol alone is
    /// not enough because the same symbol can be requested with different
    /// accessibility descriptions by different callers.
    ///
    /// The images are immutable template images, so sharing one instance
    /// between several buttons or image views is safe.
    private static var cache: [String: NSImage] = [:]

    /// - Parameters:
    ///   - symbol: the SF Symbol name.
    ///   - accessibility: the accessibility description of the image.
    ///   - logContext: used in the "SF Symbol unavailable" log line so the
    ///     three original messages keep their distinct text.
    /// - Returns: the cached image when this symbol and accessibility
    ///   description were resolved before, otherwise a freshly resolved image.
    ///   A failed resolution is logged and not cached, so a symbol that becomes
    ///   available later is picked up on the next call.
    static func make(_ symbol: String, accessibility: String, logContext: String) -> NSImage? {
        let key = "\(symbol)|\(accessibility)"
        if let cached = cache[key] {
            return cached
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) else {
            log("SF Symbol unavailable: \(symbol) (\(logContext))")
            return nil
        }
        cache[key] = image
        return image
    }

    /// True when the system provides the symbol. Probing is silent, unlike
    /// `make`, so the optional Control Strip symbols can be listed at launch
    /// without logging every candidate that is unavailable.
    static func exists(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) != nil
    }
}
