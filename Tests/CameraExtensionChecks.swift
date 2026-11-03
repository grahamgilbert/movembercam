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
        try checkQRControl(camera, sink: sink, source: source)
        try checkDemand(source: source, sink: sink)
    }

    static func checkDemand(source: CameraStream, sink: CameraStream) throws {
        func demand() throws -> String? {
            try source.streamProperties(forProperties: [CameraStreamDemand.property])
                .propertiesDictionary[CameraStreamDemand.property]?.value as? String
        }
        try check(source.availableProperties.contains(CameraStreamDemand.property) &&
                  !sink.availableProperties.contains(CameraStreamDemand.property), "Only meeting output exposes camera demand")
        try check(try demand() == "0", "Idle virtual camera does not request physical capture")
        try source.startStream()
        try source.startStream()
        try check(try demand() == "1", "Meeting consumers request physical capture without an app writer")
        try source.stopStream()
        try check(try demand() == "1", "Capture stays requested while another consumer remains")
        try source.stopStream()
        try check(try demand() == "0", "Last consumer releases physical capture")
        try source.stopStream()
        try check(try demand() == "0", "Extra stop cannot make demand negative")
        let write = CMIOExtensionStreamProperties(dictionary: [CameraStreamDemand.property:
            CMIOExtensionPropertyState<AnyObject>(value: "1" as NSString)])
        var rejected = false
        do { try source.setStreamProperties(write) } catch { rejected = true }
        try check(try rejected && demand() == "0", "Clients cannot write their own demand state")
    }

    static func checkQRControl(_ camera: CameraDevice, sink: CameraStream, source: CameraStream) throws {
        try check(sink.availableProperties.contains(FrameQRCode.controlProperty) &&
                  !source.availableProperties.contains(FrameQRCode.controlProperty), "Only the input stream exposes the QR control channel")
        let qr = FrameQRCode(url: "https://example.com/" + String(repeating: "x", count: 200),
                             area: CGRect(x: 40, y: 76, width: 216, height: 216))
        let encoded = try FrameQRCodeUpdate(qrCode: qr, effectiveTime: 1).encoded()
        let properties = CMIOExtensionStreamProperties(dictionary: [FrameQRCode.controlProperty:
            CMIOExtensionPropertyState<AnyObject>(value: encoded as NSString)])
        try sink.setStreamProperties(properties)
        try check(camera.qrControlValue == encoded, "QR control data reaches the device without frame attachments")
        let read = try sink.streamProperties(forProperties: [FrameQRCode.controlProperty])
        try check(read.propertiesDictionary[FrameQRCode.controlProperty]?.value as? String == encoded,
                  "QR control property reads back its current value")
        for value in ["invalid JSON", try FrameQRCodeUpdate(qrCode: FrameQRCode(url: qr.url,
            area: CGRect(x: 9000, y: 0, width: 216, height: 216)), effectiveTime: 1).encoded()] {
            let invalid = CMIOExtensionStreamProperties(dictionary: [FrameQRCode.controlProperty:
                CMIOExtensionPropertyState<AnyObject>(value: value as NSString)])
            var rejected = false
            do { try sink.setStreamProperties(invalid) } catch { rejected = true }
            try check(rejected && camera.qrControlValue == encoded, "Malformed QR updates leave the active control unchanged")
        }
        try check(camera.qrCode(at: CMTime(seconds: 0.5, preferredTimescale: 1000)) == nil &&
                  camera.qrCode(at: CMTime(seconds: 1.5, preferredTimescale: 1000)) == qr,
                  "Queued frames use QR controls effective at their own capture timestamp")
        let disabled = try FrameQRCodeUpdate(qrCode: nil, effectiveTime: 2).encoded()
        try sink.setStreamProperties(CMIOExtensionStreamProperties(dictionary: [FrameQRCode.controlProperty:
            CMIOExtensionPropertyState<AnyObject>(value: disabled as NSString)]))
        try check(try FrameQRCodeUpdate.decode(camera.qrControlValue, format: .hd720).qrCode == nil,
                  "Disabling the overlay clears QR reconstruction in the extension")
        try check(camera.qrCode(at: CMTime(seconds: 1.5, preferredTimescale: 1000)) == qr &&
                  camera.qrCode(at: CMTime(seconds: 2, preferredTimescale: 1000)) == nil,
                  "A bypass update does not change the QR of earlier queued frames")
        try select(1, on: sink)
        try check(camera.qrControlValue.isEmpty, "Changing input resolution clears stale QR controls")
    }

    static func main() {
        do { try CameraProvider.queue.sync { try run() } }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
