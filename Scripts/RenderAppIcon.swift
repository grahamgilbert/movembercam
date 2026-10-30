import AppKit
import Foundation

// Render the app's existing Mo artwork as a camera icon at every macOS icon size.
guard CommandLine.arguments.count == 3,
      let logo = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Usage: RenderAppIcon.swift LOGO.png OUTPUT_DIRECTORY\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let mask = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.width, pixelsHigh: source.height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
    bytesPerRow: source.width * 4, bitsPerPixel: 32)!
let bytes = mask.bitmapData!
let context = CGContext(data: bytes, width: source.width, height: source.height,
    bitsPerComponent: 8, bytesPerRow: mask.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
for pixel in 0..<(source.width * source.height) {
    let offset = pixel * 4
    let opacity = 255 - bytes[offset]
    bytes[offset] = 250
    bytes[offset + 1] = 245
    bytes[offset + 2] = 227
    bytes[offset + 3] = opacity
}
let mo = NSImage(size: logo.size)
mo.addRepresentation(mask)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSGraphicsContext.current!.imageInterpolation = .high

        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                xRadius: 202, yRadius: 202)
        NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.19, alpha: 1).setFill()
        tile.fill()
        let cream = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.89, alpha: 1)
        cream.setStroke()
        let camera = NSBezierPath(roundedRect: NSRect(x: 187, y: 285, width: 650, height: 442),
                                  xRadius: 90, yRadius: 90)
        camera.lineWidth = 34
        camera.stroke()
        cream.setFill()
        NSBezierPath(roundedRect: NSRect(x: 300, y: 715, width: 208, height: 57),
                     xRadius: 22, yRadius: 22).fill()
        NSBezierPath(ovalIn: NSRect(x: 745, y: 630, width: 34, height: 34)).fill()

        let moRect = NSRect(x: 260, y: 390, width: 504, height: 210)
        mo.draw(in: moRect)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 { try png.write(to: output.appendingPathComponent("AppIcon.png")) }
    }
}
print(iconset.path)
