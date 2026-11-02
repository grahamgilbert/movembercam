import CoreMediaIO
import Foundation

/// Exercises the real stream property handlers without installing the extension or
/// opening a physical camera. Keep timers and property changes on the provider queue.
@main
enum CameraExtensionChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func select(_ index: Int, on stream: CameraStream) throws {
        let properties = CMIOExtensionStreamProperties(dictionary: [:])
        properties.activeFormatIndex = index
        try stream.setStreamProperties(properties)
    }

    static func run() throws {
        let provider = CameraProvider()
        try provider.setUp()
        let camera = provider.provider.devices[0].source as! CameraDevice
        let source = camera.device.streams[0].source as! CameraStream
        let sink = camera.device.streams[1].source as! CameraStream
        try check(source.formats.count == VideoFormat.supported.count && sink.formats.count == source.formats.count,
                  "Source and sink advertise every supported resolution")
        for (index, format) in VideoFormat.supported.enumerated() {
            try select(index, on: sink)
            let properties = try source.streamProperties(forProperties: [.streamActiveFormatIndex])
            try check(properties.activeFormatIndex == index && source.activeFormat == format,
                      "Idle source follows capture at \(format.width) × \(format.height)")
        }
        try select(1, on: source)
        try source.startStream()
        try select(3, on: sink)
        try check(source.activeFormat == VideoFormat(width: 1920, height: 1080),
                  "Active meeting keeps its 1080p output when capture changes to 4K")
        try select(2, on: source)
        try check(source.activeFormat == VideoFormat(width: 2560, height: 1440),
                  "Meeting can negotiate another advertised output size")
        try source.stopStream()
        try check(source.activeFormat == VideoFormat(width: 3840, height: 2160),
                  "After meeting closes, default output returns to the capture resolution")
        var rejected = false
        do { try select(-1, on: source) } catch { rejected = true }
        try check(rejected && source.activeFormatIndex == 3, "Invalid format index leaves active resolution unchanged")
        let invalidDuration = CMIOExtensionStreamProperties(dictionary: [:])
        invalidDuration.activeFormatIndex = 0
        invalidDuration.frameDuration = CMTime(value: 1, timescale: 60)
        rejected = false
        do { try source.setStreamProperties(invalidDuration) } catch { rejected = true }
        try check(rejected && source.activeFormatIndex == 3, "Unsupported frame rate rejects the whole property change")
        try select(0, on: sink)
        try check(source.activeFormat == .hd720, "Switching back to a 720p camera resets source and sink")
    }

    static func main() {
        do { try CameraProvider.queue.sync { try run() } }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
