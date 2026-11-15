// Draws the AndroMac app icon (the AM monogram on the teal-to-blue tile) and writes an .iconset folder.
// Usage: swift make_icon.swift <output.iconset>   then   iconutil -c icns <output.iconset>
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icons sit on a rounded tile inset from the canvas, with a soft shadow underneath.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let colors = [NSColor(srgbRed: 0.12, green: 0.71, blue: 0.59, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.42, blue: 0.55, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // The mark is designed on a 512 grid with y pointing down; place it on the tile.
    let k = tile.width / 512
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * k, y: tile.maxY - y * k) }
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(44 * k)
    ctx.move(to: p(92, 384)); ctx.addLine(to: p(176, 136)); ctx.addLine(to: p(256, 330)); ctx.addLine(to: p(336, 136)); ctx.addLine(to: p(420, 384))
    ctx.strokePath()
    ctx.setLineWidth(36 * k)
    ctx.move(to: p(136, 286)); ctx.addLine(to: p(214, 286))
    ctx.strokePath()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
