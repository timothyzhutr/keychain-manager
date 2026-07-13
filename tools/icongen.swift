import AppKit

// --- Icon generator: key glyph on an indigo squircle, macOS Big Sur-style ---

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let topColor    = NSColor(srgbRed: 0.49, green: 0.45, blue: 0.98, alpha: 1) // #7D73FA violet
let bottomColor = NSColor(srgbRed: 0.24, green: 0.13, blue: 0.58, alpha: 1) // #3D2194 deep indigo

func tintedSymbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let out = NSImage(size: base.size)
    out.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: base.size)
    base.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func renderIcon(px: Int) -> Data {
    let side = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background
    let margin = side * 0.085
    let rect = NSRect(x: margin, y: margin, width: side - 2*margin, height: side - 2*margin)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    NSGradient(colors: [topColor, bottomColor])!.draw(in: rect, angle: -90)

    // Soft top gloss
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    gloss.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)

    // Key glyph, centered with a soft shadow
    let glyph = tintedSymbol("key.fill", pointSize: side * 0.5)
    let fit = side * 0.46
    let scale = fit / max(glyph.size.width, glyph.size.height)
    let gw = glyph.size.width * scale, gh = glyph.size.height * scale
    let gRect = NSRect(x: (side - gw)/2, y: (side - gh)/2, width: gw, height: gh)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = side * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()
    glyph.draw(in: gRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (filename, pixel size)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),("icon_512x512@2x.png", 1024),
]

for (name, px) in variants {
    let data = renderIcon(px: px)
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("wrote \(variants.count) images to \(outDir)")
