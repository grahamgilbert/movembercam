import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo

/// Confine to the video processing queue. The static overlay is rebuilt only on settings changes.
final class FrameCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool
    private var description: CMVideoFormatDescription
    private var overlay: CIImage
    private(set) var configuration: OverlayConfiguration
    var isOverlayEnabled = true
    private let logo: CGImage?
    private(set) var format = VideoFormat.hd720
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: format.width, height: format.height) }

    init(configuration: OverlayConfiguration, logo: CGImage?) throws {
        self.configuration = try configuration.validated()
        self.logo = logo
        pool = try VideoFormat.hd720.pool()
        description = try VideoFormat.hd720.description()
        overlay = CIImage(cgImage: try Self.makeOverlay(configuration: self.configuration, logo: logo))
    }

    func configure(_ configuration: OverlayConfiguration) throws {
        let valid = try configuration.validated()
        let image = try Self.makeOverlay(configuration: valid, logo: logo, format: format)
        self.configuration = valid
        overlay = CIImage(cgImage: image)
    }

    func render(_ input: CVPixelBuffer?, at time: CMTime) throws -> CMSampleBuffer {
        if let input {
            let incoming = VideoFormat(input)
            if incoming != format {
                let newPool = try incoming.pool()
                let newDescription = try incoming.description()
                let newOverlay = try Self.makeOverlay(configuration: configuration, logo: logo, format: incoming)
                pool = newPool
                description = newDescription
                overlay = CIImage(cgImage: newOverlay)
                format = incoming
            }
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output)
        guard status == kCVReturnSuccess, let output else { throw VideoError.operation("Allocate video frame", status) }
        var background = CIImage(color: CIColor(red: 0.075, green: 0.085, blue: 0.085)).cropped(to: bounds)
        if let input {
            var camera = CIImage(cvPixelBuffer: input)
            let extent = camera.extent
            camera = camera.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let scale = max(bounds.width / extent.width, bounds.height / extent.height)
            camera = camera.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            camera = camera.transformed(by: CGAffineTransform(
                translationX: (bounds.width - extent.width * scale) / 2,
                y: (bounds.height - extent.height * scale) / 2))
            if configuration.mirrorCamera {
                camera = camera.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
            }
            background = camera.cropped(to: bounds)
        }
        // Mirror only the physical camera, so the QR code and lettering stay readable.
        let image = isOverlayEnabled ? overlay.composited(over: background) : background
        context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
        return try VideoFormat.sample(output, at: time, description: description)
    }

    func preview(_ sample: CMSampleBuffer) -> CGImage? {
        guard let buffer = sample.imageBuffer else { return nil }
        return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: bounds)
    }

    static func makeOverlay(configuration: OverlayConfiguration, logo: CGImage?, format: VideoFormat = .hd720) throws -> CGImage {
        guard let bitmap = CGContext(data: nil, width: format.width, height: format.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VideoError.message("Unable to create the overlay canvas.")
        }
        let layoutScale = min(CGFloat(format.width) / 1280, CGFloat(format.height) / 720)
        bitmap.scaleBy(x: layoutScale, y: layoutScale)
        let canvasWidth = CGFloat(format.width) / layoutScale
        let canvasHeight = CGFloat(format.height) / layoutScale
        let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ink = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.08, alpha: 1)
        let x: CGFloat = configuration.corner == .right ? canvasWidth - 268 : 28
        let card = CGRect(x: x, y: 28, width: 240, height: 276)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()

        func text(_ string: String, rect: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold,
                  color: NSColor = ink, centered: Bool = true) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .left
            (string as NSString).draw(in: rect, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                .paragraphStyle: paragraph
            ])
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(configuration.qrURL.utf8)
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage else { throw VideoError.message("Unable to generate the QR code.") }
        // Four modules of white quiet zone on every edge; integer scaling keeps modules sharp.
        let modules = Int(qr.extent.width)
        let scale = max(1, Int(216 * layoutScale) / (modules + 8))
        let size = CGFloat(modules * scale) / layoutScale
        let qrContext = CIContext()
        guard let qrImage = qrContext.createCGImage(qr, from: qr.extent) else {
            throw VideoError.message("Unable to draw the QR code.")
        }
        bitmap.interpolationQuality = .none
        let qrX = floor((x + (240 - size) / 2) * layoutScale) / layoutScale
        let qrY = floor((76 + (216 - size) / 2) * layoutScale) / layoutScale
        bitmap.draw(qrImage, in: CGRect(x: qrX, y: qrY, width: size, height: size))

        var fontSize: CGFloat = 17
        while fontSize > 6 && (configuration.displayURL as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width > 216 { fontSize -= 0.5 }
        text(configuration.displayURL, rect: CGRect(x: x + 12, y: 42, width: 216, height: 25), size: fontSize)

        let brand = CGRect(x: 28, y: canvasHeight - 116, width: 188, height: 88)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: brand, xRadius: 14, yRadius: 14).fill()
        if let logo {
            let ratio = CGFloat(logo.width) / CGFloat(logo.height)
            let width = min(112, 34 * ratio)
            let height = width / ratio
            bitmap.interpolationQuality = .high
            bitmap.draw(logo, in: CGRect(x: brand.midX - width / 2, y: brand.minY + 41, width: width, height: height))
        }
        text("MOVEMBER", rect: CGRect(x: 40, y: brand.minY + 14, width: 164, height: 23), size: 20, weight: .black)
        guard let image = bitmap.makeImage() else { throw VideoError.message("Unable to finish the overlay.") }
        return image
    }
}
