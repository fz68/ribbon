// Builds Ribbon.icns from the Ribbon artwork.
//
//   swift Tools/make-icons.swift <input.svg> <output.icns>
//
// The artwork is one black path on a transparent canvas, so the icon is a light
// rounded-rectangle tile with that glyph centred on it. Everything is drawn
// from scratch with AppKit/Core Graphics; the .icns container comes from
// iconutil.

import AppKit
import Foundation

/// Empty space around the tile, as a fraction of the canvas side.
let largeInsetRatio = 0.08

/// Empty space around the tile for the 16 and 32 px entries, as a fraction of
/// the canvas side. It is tighter than `largeInsetRatio` so the glyph can grow.
let smallInsetRatio = 0.04

/// Corner radius, as a fraction of the tile side (the macOS icon squircle look).
let cornerRadiusRatio = 0.2237

/// Visible glyph width, as a fraction of the tile side.
let largeGlyphWidthRatio = 0.55

/// Visible glyph width for the 16 and 32 px entries, as a fraction of the tile
/// side. It is larger than `largeGlyphWidthRatio` because so few pixels have to
/// describe the glyph.
let smallGlyphWidthRatio = 0.74

/// Measured visible width of the glyph inside RibbonTemplate.svg. The artwork
/// canvas is square, so its side has to be this much wider than the glyph.
let artworkGlyphWidthRatio = 0.7912

/// Pixel sizes iconutil expects; the name encodes the point size and scale.
let iconsetEntries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icons: \(message)\n".utf8))
    exit(1)
}

/// Opaque sRGB colour from a 0xRRGGBB literal.
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

func sRGB() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// Square, transparent, premultiplied-RGBA bitmap context at `size` pixels.
func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: sRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot create a \(size)x\(size) bitmap context")
    }
    return context
}

/// Draws one icon at `size` pixels into `context`.
func drawIcon(size: Int, artwork: NSImage, into context: CGContext) {
    let side = CGFloat(size)
    let inset = (size >= 64 ? largeInsetRatio : smallInsetRatio) * side
    let tileSide = side - 2 * inset
    let tileRect = CGRect(x: inset, y: inset, width: tileSide, height: tileSide)
    let cornerRadius = cornerRadiusRatio * tileSide
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)

    // Work in image coordinates (y grows downwards) so the gradient and the
    // shadow offset read top-to-bottom the way the icon does.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Drop shadow: black at 22%, nudged down and blurred. Only the large
    // entries can show it, and it only peeks out below the tile.
    //
    // NSShadow measures its offset in the current graphics context, and this
    // one is flipped so that +y is down the image. A negative height therefore
    // pushes the shadow down the picture, which is the way the light falls.
    if size >= 128 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -0.025 * side)
        shadow.shadowBlurRadius = 0.05 * side
        context.saveGState() // the shadow colour and offset live in the gstate
        shadow.set()
        context.addPath(tilePath)
        context.setFillColor(rgb(0xFFFFFF)) // opaque silhouette for the shadow
        context.fillPath()
        context.restoreGState()
    }

    // Tile fill: white at the top fading to a cool light grey at the bottom.
    // The gradient has to reach past both ends of the tile, otherwise Core
    // Graphics leaves the pixels that straddle the tile edge unpainted and the
    // top and bottom rows lose their antialiasing.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    if let gradient = CGGradient(colorsSpace: sRGB(),
                                 colors: [rgb(0xFFFFFF), rgb(0xE6E6EC)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: tileRect.midX, y: tileRect.minY),
                                   end: CGPoint(x: tileRect.midX, y: tileRect.maxY),
                                   options: [.drawsBeforeStartLocation,
                                             .drawsAfterEndLocation])
    }
    context.restoreGState()

    // Hairline border, stroked along a path inset by half the line width so it
    // sits fully inside the rounded rect.
    if size >= 64 {
        let lineWidth = max(1, side / 512)
        let borderRect = tileRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let borderRadius = max(0, cornerRadius - lineWidth / 2)
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: borderRadius,
                               cornerHeight: borderRadius, transform: nil))
        context.setStrokeColor(rgb(0xC6C6D0))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    // Glyph: the artwork is already a black path, so drawing it as-is is the
    // black glyph. Its canvas is wider than the glyph, hence the division.
    let glyphWidth = (size >= 64 ? largeGlyphWidthRatio : smallGlyphWidthRatio) * tileSide
    let artworkSide = glyphWidth / artworkGlyphWidthRatio
    let artworkRect = CGRect(x: tileRect.midX - artworkSide / 2,
                             y: tileRect.midY - artworkSide / 2,
                             width: artworkSide, height: artworkSide)
    artwork.draw(in: artworkRect, from: .zero, operation: .sourceOver, fraction: 1)
}

func writePNG(_ context: CGContext, to url: URL) {
    guard let image = context.makeImage() else {
        fail("cannot snapshot \(url.lastPathComponent)")
    }
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fail("cannot encode \(url.lastPathComponent) as PNG")
    }
    do {
        try data.write(to: url)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
}

func runIconutil(iconset: URL, output: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    do {
        try process.run()
    } catch {
        fail("cannot run iconutil: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("iconutil failed with status \(process.terminationStatus)")
    }
}

func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        fail("usage: swift Tools/make-icons.swift <input.svg> <output.icns>")
    }
    let inputURL = URL(fileURLWithPath: arguments[1])
    let outputURL = URL(fileURLWithPath: arguments[2])

    guard let artwork = NSImage(contentsOf: inputURL) else {
        fail("cannot load artwork at \(inputURL.path)")
    }

    // RIBBON_ICON_KEEP_ICONSET=<dir> keeps the intermediate PNGs (useful when
    // inspecting the full-resolution render); otherwise it is a temp dir.
    let keepDirectory = ProcessInfo.processInfo.environment["RIBBON_ICON_KEEP_ICONSET"]
        .flatMap { $0.isEmpty ? nil : $0 }
    let workRoot: URL
    if let keepDirectory {
        workRoot = URL(fileURLWithPath: keepDirectory, isDirectory: true)
    } else {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ribbon-icon-\(UUID().uuidString)", isDirectory: true)
    }
    let iconsetURL = workRoot.appendingPathComponent("Ribbon.iconset", isDirectory: true)

    // Cleaning up has to be registered at function scope: a `defer` inside an
    // `if` block would fire as soon as that block ends, i.e. before rendering.
    defer {
        if keepDirectory == nil {
            try? FileManager.default.removeItem(at: workRoot)
        }
    }

    try? FileManager.default.removeItem(at: iconsetURL)
    do {
        try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    } catch {
        fail("cannot create working directories: \(error.localizedDescription)")
    }

    for entry in iconsetEntries {
        let context = makeContext(size: entry.size)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(entry.size), height: CGFloat(entry.size))
        context.clear(bounds)
        drawIcon(size: entry.size, artwork: artwork, into: context)
        writePNG(context, to: iconsetURL.appendingPathComponent(entry.name))
    }

    runIconutil(iconset: iconsetURL, output: outputURL)

    let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? NSNumber
    print("\(outputURL.path) (\(bytes?.intValue ?? 0) bytes)")
}

main()
