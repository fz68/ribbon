import Cocoa

/// The monochrome menu bar icon.
///
/// The artwork is a single black path on a transparent background. It is marked
/// as a template image, so AppKit uses its alpha as the mask and paints it in
/// the menu bar foreground colour, which keeps it legible in light and dark
/// menu bars alike.
///
/// The image is resolved once, lazily, on first access. Artwork is read from
/// the app bundle when there is one and from the source tree otherwise, because
/// `swift run` and `swift test` are not wrapped in a bundle yet.
enum StatusItemIcon {
    /// The name of the artwork inside the app bundle, without the extension.
    static let resourceName = "RibbonTemplate"

    /// The drawn size of the icon in points.
    ///
    /// The artwork is square and far larger than the menu bar, so it is scaled
    /// down to this size instead of being used at its intrinsic resolution.
    static let pointSize = NSSize(width: 18, height: 18)

    /// The template image for the menu bar, or `nil` when the artwork cannot be
    /// found or read.
    static let image: NSImage? = loadImage()

    /// The file the artwork is read from.
    ///
    /// The app bundle is asked first, which is the layout the Makefile builds
    /// under build/Ribbon.app. The source tree is the fallback for `swift run`
    /// and `swift test`, where `Bundle.main` is not the app bundle.
    ///
    /// - Returns: the URL of an existing artwork file, or `nil` when there is
    ///   none.
    static func resourceURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "svg") {
            return bundled
        }
        // .../Sources/StatusItemIcon.swift -> .../Sources -> the repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceTree = root.appendingPathComponent("Resources/\(resourceName).svg")
        return FileManager.default.fileExists(atPath: sourceTree.path) ? sourceTree : nil
    }

    /// Loads the artwork and configures it as a menu bar template image.
    ///
    /// - Returns: the configured image, or `nil` when the artwork is missing or
    ///   cannot be read.
    private static func loadImage() -> NSImage? {
        guard let url = resourceURL(), let image = NSImage(contentsOf: url) else {
            log("menu bar icon unavailable: \(resourceName).svg")
            return nil
        }
        image.isTemplate = true
        image.size = pointSize
        image.accessibilityDescription = "Ribbon"
        return image
    }
}
