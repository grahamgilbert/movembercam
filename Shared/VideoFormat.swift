import CoreMedia
import CoreVideo
import Foundation

enum VideoFormat {
    static let width = 1280
    static let height = 720
    static let fps: Int32 = 30
    static let duration = CMTime(value: 1, timescale: fps)
    static let cameraName = "MovemberCam"
    static let extensionIdentifier = "com.grahamgilbert.MovemberCam.CameraExtension"
    static let deviceID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81011")!
    static let sourceID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81012")!
    static let sinkID = UUID(uuidString: "B7CF6085-3B04-41A3-AB8F-790BABE81013")!

    static func description() throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA, width: Int32(width), height: Int32(height),
            extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw VideoError.operation("Create video format", status) }
        return description
    }

    static func pool() throws -> CVPixelBufferPool {
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
