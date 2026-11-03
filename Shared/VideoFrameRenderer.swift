import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreMediaIO
import CoreVideo

/// Property-list metadata accompanies the pixel buffer through the video pipeline.
/// Retain the QR's white drawing area so a converter can replace it on its own pixel grid.
struct FrameQRCode: Equatable, Codable {
    static let controlProperty = CMIOExtensionProperty(rawValue: "4cc_mqrc_glob_0000")
    static let controlSelector: UInt32 = 0x6d717263
    private static let key = "com.grahamgilbert.MovemberCam.QRCode" as CFString
    let url: String
    let area: CGRect

    init(url: String, area: CGRect) {
        self.url = url
        self.area = area
    }

    init?(_ buffer: CVPixelBuffer) {
        guard let value = CVBufferCopyAttachment(buffer, Self.key, nil) as? [String: Any],
              let url = value["url"] as? String, !url.isEmpty, url.utf8.count <= 220,
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let area = CGRect(x: x, y: y, width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard bounds.contains(area) else { return nil }
        self.init(url: url, area: area)
    }

    func attach(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, Self.key, ["url": url, "x": Double(area.minX), "y": Double(area.minY),
            "width": Double(area.width), "height": Double(area.height)] as CFDictionary, .shouldPropagate)
    }

    static func remove(from buffer: CVPixelBuffer) { CVBufferRemoveAttachment(buffer, key) }

    func rasterized(in bounds: CGRect) throws -> (image: CIImage, area: CGRect)? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.utf8)
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { throw VideoError.message("Unable to generate the QR code.") }
        let modules = code.extent.width
        let minimum = modules + 8
        guard min(bounds.width, bounds.height) >= minimum else { return nil }
        // Letterboxing a square camera can make the original card too small.
        // Grow its white QR area upward, preserving the written label below it.
        var drawingArea = area.integral
        let width = max(drawingArea.width, minimum)
        let height = max(drawingArea.height, minimum)
        drawingArea = CGRect(x: max(bounds.minX, min(floor(drawingArea.midX - width / 2), bounds.maxX - width)),
            y: max(bounds.minY, min(drawingArea.minY, bounds.maxY - height)), width: width, height: height)
        let scale = floor(min(drawingArea.width, drawingArea.height) / minimum)
        let size = modules * scale
        let x = floor(drawingArea.midX - size / 2)
        let y = floor(drawingArea.midY - size / 2)
        let pixels = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x - code.extent.minX * scale,
                                              y: y - code.extent.minY * scale))
        return (pixels.composited(over: CIImage(color: .white).cropped(to: drawingArea)), drawingArea)
    }
}

/// CMIO drops arbitrary image-buffer attachments at process boundaries. Send QR
/// changes through an explicit stream property, with timestamps for queued frames.
struct FrameQRCodeUpdate: Codable {
    let qrCode: FrameQRCode?
    let effectiveTime: Double

    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

    static func decode(_ value: String, format: VideoFormat) throws -> Self {
        guard value.utf8.count <= 2048,
              let update = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
              update.effectiveTime.isFinite, update.effectiveTime >= 0 else {
            throw VideoError.message("Invalid QR control data.")
        }
        if let qr = update.qrCode {
            let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
            guard !qr.url.isEmpty, qr.url.utf8.count <= 220,
                  [qr.area.minX, qr.area.minY, qr.area.width, qr.area.height].allSatisfy(\.isFinite),
                  qr.area.width > 0, qr.area.height > 0, bounds.contains(qr.area) else {
                throw VideoError.message("Invalid QR drawing area.")
            }
        }
        return update
    }
}

/// Queue-confined conversion for the virtual camera. Preserve the whole composited
/// image when aspect ratios differ so the QR card and branding are never cropped.
final class VideoFrameRenderer {
    let format: VideoFormat
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool
    private let description: CMVideoFormatDescription
    private var blank: CVPixelBuffer?
    private var cachedQRCode: FrameQRCode?
    private var cachedQRImage: CIImage?
    private var cachedOutputQRCode: FrameQRCode?

    init(format: VideoFormat) throws {
        self.format = format
        pool = try format.pool()
        description = try format.description()
    }

    func render(_ input: CVPixelBuffer?, at time: CMTime) throws -> CMSampleBuffer {
        if let input, VideoFormat(input) == format,
           CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA {
            return try VideoFormat.sample(input, at: time, description: description)
        }
        if input == nil, let blank {
            return try VideoFormat.sample(blank, at: time, description: description)
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output)
        guard status == kCVReturnSuccess, let output else { throw VideoError.operation("Allocate output frame", status) }
        let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        var image = CIImage(color: CIColor(red: 0.075, green: 0.085, blue: 0.085)).cropped(to: bounds)
        var outputQRCode: FrameQRCode?
        if let input {
            let source = CIImage(cvPixelBuffer: input)
            let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let translation = CGAffineTransform(
                translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY)
            let centered = scaled.transformed(by: translation)
            image = centered.composited(over: image).cropped(to: bounds)
            if let qrCode = FrameQRCode(input) {
                let area = qrCode.area.applying(CGAffineTransform(scaleX: scale, y: scale)).applying(translation)
                let converted = FrameQRCode(url: qrCode.url, area: area)
                if converted != cachedQRCode {
                    let rasterized = try converted.rasterized(in: bounds)
                    cachedQRImage = rasterized?.image
                    cachedOutputQRCode = rasterized.map { FrameQRCode(url: converted.url, area: $0.area) } ?? converted
                    cachedQRCode = converted
                }
                if let cachedQRImage { image = cachedQRImage.composited(over: image) }
                outputQRCode = cachedOutputQRCode
            }
        }
        context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // Pools reuse buffers; bypassed and idle frames must not inherit an old QR.
        FrameQRCode.remove(from: output)
        outputQRCode?.attach(to: output)
        if input == nil { blank = output }
        return try VideoFormat.sample(output, at: time, description: description)
    }
}
