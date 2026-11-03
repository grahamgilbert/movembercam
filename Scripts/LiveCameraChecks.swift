import AppKit
import CoreMediaIO
import Vision

/// Manual cross-process CMIO check. Uses synthetic frames and never records video.
/// Default mode requires capture stopped in MovemberCam and no other sink writer.
/// --read-only observes the running app; --360 and --long test its low-resolution QR.
/// See docs/DEVELOPMENT.md for building and running against an approved extension.
@main enum LiveCameraChecks {
    static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(scope), mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
    static func ids(_ object: CMIOObjectID, _ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
        var property = address(selector, scope: scope); var bytes: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var values = [CMIOObjectID](repeating: 0, count: Int(bytes) / 4); var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &property, 0, nil, bytes, &used, &values) == noErr else { return [] }
        return Array(values.prefix(Int(used) / 4))
    }
    static func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else { throw VideoError.operation(name, status) }
    }
    static func formats(_ stream: CMIOStreamID) throws -> [CMFormatDescription] {
        var property = address(kCMIOStreamPropertyFormatDescriptions); var value: Unmanaged<CFArray>?; var used: UInt32 = 0
        try check(CMIOObjectGetPropertyData(stream, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &used, &value), "Read formats")
        return value!.takeRetainedValue() as! [CMFormatDescription]
    }
    static func setFormat(_ format: VideoFormat, _ stream: CMIOStreamID) throws {
        guard let description = try formats(stream).first(where: {
            let size = CMVideoFormatDescriptionGetDimensions($0)
            return size.width == format.width && size.height == format.height
        }) else { throw VideoError.message("Installed extension does not advertise \(format)") }
        var value = Unmanaged.passUnretained(description); var property = address(kCMIOStreamPropertyFormatDescription)
        try check(CMIOObjectSetPropertyData(stream, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "Set format")
    }
    static func queue(_ stream: CMIOStreamID) throws -> CMSimpleQueue {
        var value: Unmanaged<CMSimpleQueue>?
        try check(CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &value), "Get stream queue")
        return value!.takeRetainedValue()
    }
    static func codes(_ buffer: CVPixelBuffer) throws -> [String] {
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
    static func run() throws {
        let deviceIDs = ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        let device = deviceIDs.first { id in
            var property = address(kCMIODevicePropertyDeviceUID); var value: Unmanaged<CFString>?; var used: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &used, &value) == noErr && value?.takeRetainedValue() as String? == VideoFormat.deviceID.uuidString
        }
        guard let device, let source = ids(device, kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeInput).first,
              let sink = ids(device, kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeOutput).first else { throw VideoError.message("MovemberCam source/sink not found") }
        let sizes = try formats(source).map { CMVideoFormatDescriptionGetDimensions($0) }
        print("Installed source formats: \(sizes)")
        fflush(stdout)
        if CommandLine.arguments.contains("--inspect") { return }
        if CommandLine.arguments.contains("--reset720") {
            try setFormat(.hd720, sink)
            try setFormat(.hd720, source)
            print("Reset source and sink to 720p for the original app")
            return
        }
        if CommandLine.arguments.contains("--read-only") {
            if CommandLine.arguments.contains("--360") { try setFormat(VideoFormat(width:640,height:360), source) }
            let incoming = try queue(source)
            try check(CMIODeviceStartStream(device, source), "Start source")
            defer { CMIODeviceStopStream(device, source) }
            let deadline = Date().addingTimeInterval(6)
            var frames = 0, metadata = 0, decoded = 0
            while Date() < deadline {
                try autoreleasepool {
                    while let pointer = CMSimpleQueueDequeue(incoming) {
                        let sample = Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeRetainedValue()
                        guard let pixels = sample.imageBuffer else { continue }
                        frames += 1
                        if FrameQRCode(pixels) != nil { metadata += 1 }
                        if frames % 10 == 0 {
                            let values = try codes(pixels)
                            let expected = "https://example.com/" + String(repeating: "x", count: 200)
                            if !values.isEmpty && (!CommandLine.arguments.contains("--long") || values == [expected]) { decoded += 1 }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            print("LIVE READ: frames=\(frames), QR metadata frames=\(metadata), decoded QR checks=\(decoded)")
            guard frames > 0, decoded >= 3 else { throw VideoError.message("Live source check failed") }
            return
        }
        let inputFormat = VideoFormat(width: 1920, height: 1080)
        try setFormat(inputFormat, sink)
        try setFormat(VideoFormat(width: 640, height: CommandLine.arguments.contains("--480") ? 480 : 360), source)
        let incoming = try queue(source), outgoing = try queue(sink)
        try check(CMIODeviceStartStream(device, source), "Start source")
        defer { CMIODeviceStopStream(device, source) }
        try check(CMIODeviceStartStream(device, sink), "Start sink")
        defer {
            CMIODeviceStopStream(device, sink)
            while let pointer = CMSimpleQueueDequeue(outgoing) { Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release() }
        }
        let config = OverlayConfiguration(qrURL: "https://example.com/" + String(repeating: "x", count: 200))
        let compositor = try FrameCompositor(configuration: config, logo: nil)
        let pool = try inputFormat.pool(); var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), 0, CVPixelBufferGetBytesPerRow(buffer!) * inputFormat.height)
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        var received = 0, metadata = 0, decoded = 0
        var sentQRControl = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try autoreleasepool {
                if CMSimpleQueueGetCount(outgoing) < CMSimpleQueueGetCapacity(outgoing) {
                    let sample = try compositor.render(buffer!, at: CMClockGetTime(CMClockGetHostTimeClock()))
                    if !sentQRControl {
                        var property = address(Int(FrameQRCode.controlSelector))
                        guard CMIOObjectHasProperty(sink, &property) else { throw VideoError.message("Installed extension lacks the QR control channel") }
                        let string = try FrameQRCodeUpdate(qrCode: FrameQRCode(sample.imageBuffer!),
                            effectiveTime: sample.presentationTimeStamp.seconds).encoded() as CFString
                        var value = Unmanaged.passUnretained(string)
                        try withExtendedLifetime(string) {
                            try check(CMIOObjectSetPropertyData(sink, &property, 0, nil,
                                UInt32(MemoryLayout.size(ofValue: value)), &value), "Set QR control")
                        }
                        sentQRControl = true
                    }
                    let pointer = Unmanaged.passRetained(sample)
                    if CMSimpleQueueEnqueue(outgoing, element: pointer.toOpaque()) != noErr { pointer.release() }
                }
                while let pointer = CMSimpleQueueDequeue(incoming) {
                    let sample = Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeRetainedValue()
                    guard let pixels = sample.imageBuffer else { continue }
                    let expected = VideoFormat(width: 640, height: CommandLine.arguments.contains("--480") ? 480 : 360)
                    guard VideoFormat(pixels) == expected else { throw VideoError.message("Unexpected negotiated output dimensions") }
                    received += 1
                    if FrameQRCode(pixels)?.url == config.qrURL { metadata += 1 }
                    if try received % 10 == 0 && codes(pixels) == [config.qrURL] { decoded += 1 }
                }
            }
            Thread.sleep(forTimeInterval: 1.0 / 30.0)
        }
        print("LIVE RESULTS: frames=\(received), QR metadata frames=\(metadata), decoded QR checks=\(decoded)")
        guard received > 0, decoded >= 3 else { throw VideoError.message("Live QR transport check failed") }
    }
    static func main() {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try run(); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
}
