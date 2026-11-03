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
    private var renderer: VideoFrameRenderer
    private var qrUpdates: [FrameQRCodeUpdate] = []
    private(set) var qrControlValue = ""
    private var latest: CVPixelBuffer?
    private var latestTime = -Double.infinity
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkRunning = false
    private var consumePending = false
    private var sinkGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init(configure: Bool) throws {
        renderer = try VideoFrameRenderer(format: .hd720)
        super.init()
        device = CMIOExtensionDevice(localizedName: VideoFormat.cameraName, deviceID: VideoFormat.deviceID,
                                     legacyDeviceID: nil, source: self)
        let formats = try VideoFormat.supported.map {
            CMIOExtensionStreamFormat(formatDescription: try $0.description(), maxFrameDuration: VideoFormat.duration,
                                      minFrameDuration: VideoFormat.duration, validFrameDurations: nil)
        }
        source = CameraStream(owner: self, id: VideoFormat.sourceID, direction: .source, formats: formats)
        sink = CameraStream(owner: self, id: VideoFormat.sinkID, direction: .sink, formats: formats)
        // AVFoundation uses the first source stream as the selectable camera.
        try device.addStream(source.stream)
        try device.addStream(sink.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "MovemberCam Auto" }
        return result
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func setFormat(index: Int, direction: CMIOExtensionStream.Direction) throws {
        if direction == .source {
            renderer = try VideoFrameRenderer(format: VideoFormat.supported[index])
        } else {
            // The app selects the sink format to match its actual frames. Default the
            // source to that format before a meeting opens it. An active meeting keeps
            // its negotiated format, even when the physical camera changes.
            if sourceClients == 0 { try source.selectFormat(index) }
            latest = nil
            latestTime = -Double.infinity
            qrUpdates.removeAll()
            qrControlValue = ""
        }
    }

    func setQRCodeUpdate(_ update: FrameQRCodeUpdate, encoded: String) {
        qrUpdates.append(update)
        if qrUpdates.count > 16 { qrUpdates.removeFirst(qrUpdates.count - 16) }
        qrControlValue = encoded
    }

    func qrCode(at time: CMTime) -> FrameQRCode? {
        qrUpdates.last(where: { $0.effectiveTime <= time.seconds })?.qrCode
    }

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
        if direction == .source {
            sourceClients = max(0, sourceClients - 1)
            if sourceClients == 0 { try? source.selectFormat(sink.activeFormatIndex) }
        }
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
        qrUpdates.removeAll()
        qrControlValue = ""
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
                          VideoFormat(buffer) == self.sink.activeFormat,
                          CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
                    let received = CMClockGetTime(CMClockGetHostTimeClock())
                    FrameQRCode.remove(from: buffer)
                    self.qrCode(at: sample.presentationTimeStamp)?.attach(to: buffer)
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
        let frame = (0...0.5).contains(age) ? latest : nil
        if let sample = try? renderer.render(frame, at: now) {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * 1_000_000_000))
        }
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: CameraDevice
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]
    private(set) var activeFormatIndex = 0
    var activeFormat: VideoFormat { VideoFormat.supported[activeFormatIndex] }

    init(owner: CameraDevice, id: UUID, direction: CMIOExtensionStream.Direction, formats: [CMIOExtensionStreamFormat]) {
        self.owner = owner
        self.direction = direction
        self.formats = formats
        super.init()
        stream = CMIOExtensionStream(localizedName: direction == .source ? "MovemberCam.Video" : "MovemberCam.Input",
            streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, FrameQRCode.controlProperty])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if direction == .sink, properties.contains(FrameQRCode.controlProperty) {
            result.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: owner.qrControlValue as NSString),
                                    forProperty: FrameQRCode.controlProperty)
        }
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = VideoFormat.duration }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, !formats.indices.contains(index) {
            throw VideoError.message("Unsupported video format.")
        }
        if let duration = streamProperties.frameDuration, CMTimeCompare(duration, VideoFormat.duration) != 0 {
            throw VideoError.message("Only 30 fps is supported.")
        }
        var qrUpdate: (FrameQRCodeUpdate, String)?
        if let property = streamProperties.propertiesDictionary[FrameQRCode.controlProperty] {
            guard direction == .sink, let value = property.value as? String else {
                throw VideoError.message("Invalid QR control property.")
            }
            let format = VideoFormat.supported[streamProperties.activeFormatIndex ?? activeFormatIndex]
            qrUpdate = (try FrameQRCodeUpdate.decode(value, format: format), value)
        }
        if let index = streamProperties.activeFormatIndex { try selectFormat(index) }
        if let (update, encoded) = qrUpdate { owner.setQRCodeUpdate(update, encoded: encoded) }
    }

    func selectFormat(_ index: Int) throws {
        // Call the owner even for the same index: selecting the initial 720p sink
        // must still reset a source left at another resolution by a previous client.
        try owner.setFormat(index: index, direction: direction)
        guard activeFormatIndex != index else { return }
        activeFormatIndex = index
        stream.notifyPropertiesChanged([.streamActiveFormatIndex:
            CMIOExtensionPropertyState<AnyObject>(value: NSNumber(value: index))])
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { direction == .source || owner.authorizeSink(client) }
    func startStream() throws { try owner.start(direction: direction) }
    func stopStream() throws { owner.stop(direction: direction) }
}
