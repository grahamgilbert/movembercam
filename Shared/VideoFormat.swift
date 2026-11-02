import CoreMedia
import CoreVideo
import Foundation

struct VideoFormat: Equatable, Hashable {
    let width: Int
    let height: Int
    static let hd720 = VideoFormat(width: 1280, height: 720)
    // Keep the advertised list stable for the lifetime of each CMIO stream. Index zero
    // remains 720p for clients that don't explicitly negotiate a format.
    static let supported: [VideoFormat] = [
        .hd720,
        VideoFormat(width: 1920, height: 1080),
        VideoFormat(width: 2560, height: 1440),
        VideoFormat(width: 3840, height: 2160),
        VideoFormat(width: 640, height: 360),
        VideoFormat(width: 640, height: 480),
        VideoFormat(width: 1280, height: 960),
        VideoFormat(width: 1600, height: 1200),
        VideoFormat(width: 1920, height: 1440)
    ]
    static let fps: Int32 = 30
    static let duration = CMTime(value: 1, timescale: fps)
    static let cameraName = "MovemberCam"
    static let extensionIdentifier = "com.grahamgilbert.MovemberCam.CameraExtension"
    static let deviceID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81011")!
    static let sourceID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81012")!
    static let sinkID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81013")!

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(_ buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
    }

    var isWithinCaptureLimit: Bool { width > 0 && height > 0 && width <= 3840 && height <= 2160 }
    var pixelCount: Int { width * height }
    var aspectRatio: Double { Double(width) / Double(height) }

    /// Prefer an exact match, then the closest aspect ratio without increasing resolution.
    /// The supplied list is read from the installed extension, including older 720p versions.
    func bestMatch(in formats: [VideoFormat]) -> VideoFormat? {
        let valid = formats.filter { $0.width > 0 && $0.height > 0 }
        if valid.contains(self) { return self }
        let smaller = valid.filter { $0.width <= width && $0.height <= height }
        return (smaller.isEmpty ? valid : smaller).min {
            let lhs = abs($0.aspectRatio - aspectRatio)
            let rhs = abs($1.aspectRatio - aspectRatio)
            if abs(lhs - rhs) > 0.0001 { return lhs < rhs }
            return smaller.isEmpty ? $0.pixelCount < $1.pixelCount : $0.pixelCount > $1.pixelCount
        }
    }

    struct CaptureMode {
        let format: VideoFormat
        let frameRateRanges: [ClosedRange<Double>]

        var frameRate: Double? {
            frameRateRanges.filter { $0.lowerBound > 0 && $0.upperBound.isFinite }.map {
                min(max(Double(VideoFormat.fps), $0.lowerBound), $0.upperBound)
            }.min { abs($0 - Double(VideoFormat.fps)) < abs($1 - Double(VideoFormat.fps)) }
        }
    }

    /// Prefer 30 fps, then the largest video mode up to UHD. If 30 fps is unavailable,
    /// use the nearest supported rate and let the existing frame limiter cap output.
    static func preferredCaptureModeIndex(in modes: [CaptureMode]) -> Int? {
        modes.indices.filter { modes[$0].format.isWithinCaptureLimit && modes[$0].frameRate != nil }.min {
            let lhs = abs(modes[$0].frameRate! - Double(fps))
            let rhs = abs(modes[$1].frameRate! - Double(fps))
            if abs(lhs - rhs) > 0.0001 { return lhs < rhs }
            return modes[$0].format.pixelCount > modes[$1].format.pixelCount
        }
    }

    func description() throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA, width: Int32(width), height: Int32(height),
            extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw VideoError.operation("Create video format", status) }
        return description
    }

    func pool() throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true
        ] as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw VideoError.operation("Create pixel buffer pool", status) }
        return pool
    }

    static func sample(_ pixelBuffer: CVPixelBuffer, at time: CMTime,
                       description: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoError.operation("Create video sample", status) }
        return sample
    }
}

enum VideoError: LocalizedError {
    case operation(String, OSStatus)
    case message(String)
    var errorDescription: String? {
        switch self {
        case let .operation(name, status): return "\(name) failed (\(status))."
        case let .message(message): return message
        }
    }
}
