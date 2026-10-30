import AppKit
import Foundation

// Native drawing keeps the installer art reproducible and its arrow aligned to the real Finder icons.
guard CommandLine.arguments.count == 3,
      let logo = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: RenderDMGBackground.swift LOGO.png OUTPUT_DIRECTORY\n", stderr)
    exit(1)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let size = NSSize(width: 760, height: 480)

for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760 * scale, pixelsHigh: 480 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create installer background")
    }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let ink = NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.15, alpha: 1)
    NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    func text(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (string as NSString).draw(in: NSRect(x: 24, y: y, width: 712, height: 44), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    text("MovemberCam", y: 394, font: .systemFont(ofSize: 32, weight: .semibold), color: ink)
    text("Drag MovemberCam to Applications", y: 354, font: .systemFont(ofSize: 17), color: .darkGray)

    // Finder icon coordinates start at the top; the canvas starts at the bottom.
    // Keep the middle clear except for the Mo and the right-pointing drag arrow.
    let logoWidth: CGFloat = 94
    let logoHeight = logoWidth * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: 380 - logoWidth / 2, y: 275, width: logoWidth, height: logoHeight))
    ink.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 302, y: 240))
    arrow.line(to: NSPoint(x: 458, y: 240))
    arrow.move(to: NSPoint(x: 440, y: 258))
    arrow.line(to: NSPoint(x: 458, y: 240))
    arrow.line(to: NSPoint(x: 440, y: 222))
    arrow.stroke()

    text("Then open MovemberCam from Applications to finish setup.", y: 54,
         font: .systemFont(ofSize: 14), color: .darkGray)
    NSGraphicsContext.restoreGraphicsState()
    let filename = scale == 1 ? "background.png" : "background@2x.png"
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
    try png.write(to: directory.appendingPathComponent(filename))
}
print(directory.appendingPathComponent("background.png").path)
