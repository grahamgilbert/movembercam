import CoreImage
import CoreMedia
import CoreVideo

/// Queue-confined conversion for the virtual camera. Preserve the whole composited
/// image when aspect ratios differ so the QR card and branding are never cropped.
final class VideoFrameRenderer {
    let format: VideoFormat
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool
    private let description: CMVideoFormatDescription
    private var blank: CVPixelBuffer?

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
        if let input {
            let source = CIImage(cvPixelBuffer: input)
            let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
            image = centered.composited(over: image).cropped(to: bounds)
        }
        context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        if input == nil { blank = output }
        return try VideoFormat.sample(output, at: time, description: description)
    }
}
