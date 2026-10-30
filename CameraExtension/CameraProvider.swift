import CoreMediaIO
import Foundation
import IOKit.audio
import os

/// CoreMediaIO delivers requests on this same serial queue; frame timers and consume completions
/// also use it, so device state is never shared across concurrent queues.
final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    static let queue = DispatchQueue(label: "MovemberCam.extension", qos: .userInteractive)
    private(set) var provider: CMIOExtensionProvider!
    private var camera: CameraDevice!

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: Self.queue)
    }

    func setUp() throws {
        camera = try CameraDevice(configure: true)
        try provider.addDevice(camera.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.disconnected(client) }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "MovemberCam" }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let videoDescription: CMVideoFormatDescription
    private let blank: CVPixelBuffer
    private var latest: CVPixelBuffer?
    private var latestTime = -Double.infinity
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkRunning = false
    private var consumePending = false
    private var sinkGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init(configure: Bool) throws {
        videoDescription = try VideoFormat.description()
        let pool = try VideoFormat.pool()
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw VideoError.operation("Create idle frame", status) }
        blank = buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            for row in 0..<VideoFormat.height {
                let pixels = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)
                for column in 0..<VideoFormat.width { pixels[column] = 0xFF141916 }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        super.init()
        device = CMIOExtensionDevice(localizedName: VideoFormat.cameraName, deviceID: VideoFormat.deviceID,
                                     legacyDeviceID: nil, source: self)
        let format = CMIOExtensionStreamFormat(formatDescription: videoDescription, maxFrameDuration: VideoFormat.duration,
                                              minFrameDuration: VideoFormat.duration, validFrameDurations: nil)
        source = CameraStream(owner: self, id: VideoFormat.sourceID, direction: .source, format: format)
        sink = CameraStream(owner: self, id: VideoFormat.sinkID, direction: .sink, format: format)
        // AVFoundation uses the first source stream as the selectable camera.
        try device.addStream(source.stream)
        try device.addStream(sink.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "MovemberCam 720p" }
        return result
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func authorizeSink(_ client: CMIOExtensionClient) -> Bool {
        // CoreMediaIO supplies the authenticated client process. Keep one active output writer.
        guard client.pid > 0,
              !sinkRunning || sinkClient?.clientID == client.clientID else { return false }
        sinkClient = client
        return true
    }

    func start(direction: CMIOExtensionStream.Direction) throws {
        if direction == .source { sourceClients += 1 }
        else {
            guard sinkClient != nil else { throw VideoError.message("The companion app has not connected.") }
            sinkRunning = true
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: CameraProvider.queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / VideoFormat.fps)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop(direction: CMIOExtensionStream.Direction) {
        if direction == .source { sourceClients = max(0, sourceClients - 1) }
        else { resetSink() }
        stopTimerIfIdle()
    }

    func disconnected(_ client: CMIOExtensionClient) {
        if sinkClient?.clientID == client.clientID { resetSink(); stopTimerIfIdle() }
    }

    private func resetSink() {
        sinkRunning = false
        sinkClient = nil
        sinkGeneration &+= 1
        consumePending = false
        latest = nil
        latestTime = -Double.infinity
    }


    private func stopTimerIfIdle() {
        if sourceClients == 0 && !sinkRunning { timer?.cancel(); timer = nil }
    }

    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if sinkRunning, let client = sinkClient, !consumePending {
            consumePending = true
            let generation = sinkGeneration
            sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, error in
                CameraProvider.queue.async {
                    guard let self, self.sinkGeneration == generation else { return }
                    self.consumePending = false
                    guard error == nil, let sample, let buffer = sample.imageBuffer,
                          CVPixelBufferGetWidth(buffer) == VideoFormat.width,
                          CVPixelBufferGetHeight(buffer) == VideoFormat.height,
                          CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
                    let received = CMClockGetTime(CMClockGetHostTimeClock())
                    self.latest = buffer
                    self.latestTime = sample.presentationTimeStamp.seconds
                    self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                        hostTimeInNanoseconds: UInt64(received.seconds * 1_000_000_000)))
                }
            }
        }
        guard sourceClients > 0 else { return }
        // Never leave a frozen private image on a call after the app stops or crashes.
        let age = now.seconds - latestTime
        let frame = (0...0.5).contains(age) ? (latest ?? blank) : blank
        if let sample = try? VideoFormat.sample(frame, at: now, description: videoDescription) {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * 1_000_000_000))
        }
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: CameraDevice
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]

    init(owner: CameraDevice, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat) {
        self.owner = owner
        self.direction = direction
        formats = [format]
        super.init()
        stream = CMIOExtensionStream(localizedName: direction == .source ? "MovemberCam.Video" : "MovemberCam.Input",
            streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = VideoFormat.duration }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index != 0 { throw VideoError.message("Only 720p is supported.") }
        if let duration = streamProperties.frameDuration, CMTimeCompare(duration, VideoFormat.duration) != 0 {
            throw VideoError.message("Only 30 fps is supported.")
        }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { direction == .source || owner.authorizeSink(client) }
    func startStream() throws { try owner.start(direction: direction) }
    func stopStream() throws { owner.stop(direction: direction) }
}
