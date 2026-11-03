import CoreMediaIO
import Foundation
import os

/// CoreMediaIO work runs on its own serial queue. Capture hands off just the latest frame.
final class VirtualCameraOutput {
    var onStatus: ((VirtualCameraStatus) -> Void)?
    var onDemand: ((Bool) -> Void)?
    private let worker = DispatchQueue(label: "MovemberCam.virtualOutput", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: CMSampleBuffer?
    private var scheduled = false
    private static let logger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "VirtualOutput")
    private var health = VirtualCameraConnectionHealth()
    private var observedDevices: [CMIODeviceID] = []
    private var supportsDemand = false
    private var lastFailureStage: String?
    private var queueIsFull = false
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var inputFormat: VideoFormat?
    private var renderer: VideoFrameRenderer?
    private var sentQRCode: FrameQRCode?
    private var didSendQRCode = false
    private var lastProbe: CFAbsoluteTime = 0
    private var deviceListener: CMIOObjectPropertyListenerBlock?
    private var demandTimer: DispatchSourceTimer?
    private var requested: Bool?
    private var status = VirtualCameraStatus.idle(isInstalled: false) {
        didSet {
            if status != oldValue {
                Self.logger.notice("Output status \(oldValue.message, privacy: .public) -> \(self.status.message, privacy: .public)")
                onStatus?(status)
            }
        }
    }

    init() {
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.lastProbe = 0
            self?.refreshAvailabilityOnWorker()
        }
        deviceListener = listener
        var property = address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, worker, listener)
        // Observe even while capture and the sink are stopped. Polling also recovers
        // missed notifications and discovers a replacement extension after an update.
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refreshAvailabilityOnWorker(forceDemand: false) }
        demandTimer = timer
        timer.resume()
    }

    deinit {
        demandTimer?.cancel()
        if let deviceListener {
            var property = address(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, worker, deviceListener)
        }
    }

    func send(_ sample: CMSampleBuffer) {
        // A single latest-frame slot, so discovery or a slow extension never backs up capture.
        lock.lock()
        pending = sample
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        worker.async { self.processLatest() }
    }

    func refreshAvailability() {
        worker.async { self.refreshAvailabilityOnWorker() }
    }

    /// Tear down the app's old sink connection after activation; leave physical capture and video clients running.
    func reconnect() {
        worker.async {
            Self.logger.notice("Reconnecting virtual camera locally")
            self.stopOnWorker(preserveCapture: true)
            self.refreshAvailabilityOnWorker()
        }
    }

    private func refreshAvailabilityOnWorker(forceDemand: Bool = true) {
        let devices = matchingDeviceIDs()
        if devices != observedDevices {
            Self.logger.notice("Discovery device count=\(devices.count, privacy: .public) ids=\(String(describing: devices), privacy: .public)")
            observedDevices = devices
            if device != 0 && !devices.contains(device) { stopOnWorker(preserveCapture: true) }
            health.reset()
            lastFailureStage = nil
        }
        supportsDemand = refreshDemandOnWorker(devices: devices, force: forceDemand)
        status = health.status(isInstalled: !devices.isEmpty, supportsDemand: supportsDemand)
        // Deliver unchanged snapshots too: installation verification may have started since the last event.
        if forceDemand { onStatus?(status) }
    }

    @discardableResult
    private func refreshDemandOnWorker(devices: [CMIODeviceID], force: Bool = false) -> Bool {
        var needed = false
        var supportsDemand = false
        var readFailed = false
        for id in devices {
            let sources = objectIDs(id, selector: kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeInput)
            for source in sources {
                var property = address(Int(CameraStreamDemand.selector))
                guard CMIOObjectHasProperty(source, &property) else { continue }
                supportsDemand = true
                var value: Unmanaged<CFString>?
                var used: UInt32 = 0
                let result = CMIOObjectGetPropertyData(source, &property, 0, nil,
                    UInt32(MemoryLayout.size(ofValue: value)), &used, &value)
                if result == noErr, let value = value?.takeRetainedValue() {
                    if value as String == "1" { needed = true }
                } else if result != noErr {
                    readFailed = true
                    recordFailure(.cannotOpen(result), stage: "read-demand")
                }
            }
        }
        // A transient failed property read is not evidence that every consumer closed.
        if readFailed && !needed { needed = requested ?? false }
        if force || requested != needed {
            if requested != needed { Self.logger.notice("Video consumer demand=\(needed, privacy: .public)") }
            requested = needed
            onDemand?(needed)
        }
        return supportsDemand
    }

    private func processLatest() {
        lock.lock()
        let sample = pending
        pending = nil
        lock.unlock()
        if let sample { sendOnWorker(sample) }
        lock.lock()
        let hasMore = pending != nil
        if !hasMore { scheduled = false }
        lock.unlock()
        if hasMore { worker.async { self.processLatest() } }
    }

    private func sendOnWorker(_ sample: CMSampleBuffer) {
        guard let input = sample.imageBuffer else { return }
        health.expectsFrames = true
        let incoming = VideoFormat(input)
        if bufferQueue != nil, incoming != inputFormat { stopOnWorker(preserveCapture: true) }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProbe > 1 {
            lastProbe = now
            if device != 0 {
                var alive: UInt32 = 0
                var address = address(kCMIODevicePropertyDeviceIsAlive)
                var used: UInt32 = 0
                let result = CMIOObjectGetPropertyData(device, &address, 0, nil,
                    UInt32(MemoryLayout.size(ofValue: alive)), &used, &alive)
                if result != noErr || alive == 0 {
                    Self.logger.warning("Sink device stopped responding code=\(result, privacy: .public)")
                    stopOnWorker(preserveCapture: true)
                }
            }
            if bufferQueue == nil { connect(format: incoming) }
        }
        guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - sample.presentationTimeStamp.seconds < 0.25,
              let bufferQueue, let renderer else { return }
        if CMSimpleQueueGetCount(bufferQueue) >= CMSimpleQueueGetCapacity(bufferQueue) {
            if !queueIsFull { Self.logger.warning("Sink queue full; waiting for extension to consume frames") }
            queueIsFull = true
            return
        }
        if queueIsFull { Self.logger.notice("Sink queue consuming frames again") }
        queueIsFull = false
        let output: CMSampleBuffer
        do { output = try renderer.render(input, at: sample.presentationTimeStamp) }
        catch {
            if case VideoError.operation(_, kCVReturnWouldExceedAllocationThreshold) = error { return }
            recordFailure(.cannotOpen(OSStatus(kCMIOHardwareUnspecifiedError)), stage: "render-frame")
            return
        }
        let qrCode = output.imageBuffer.flatMap(FrameQRCode.init)
        if !didSendQRCode || qrCode != sentQRCode {
            var property = address(Int(FrameQRCode.controlSelector))
            // Older 720p extensions need no extra conversion and have no control property.
            if CMIOObjectHasProperty(stream, &property) {
                guard let encoded = try? FrameQRCodeUpdate(qrCode: qrCode,
                    effectiveTime: output.presentationTimeStamp.seconds).encoded() else { return }
                let value = encoded as CFString
                var unmanaged = Unmanaged.passUnretained(value)
                let result = withExtendedLifetime(value) {
                    CMIOObjectSetPropertyData(stream, &property, 0, nil,
                        UInt32(MemoryLayout.size(ofValue: unmanaged)), &unmanaged)
                }
                guard result == noErr else { recordFailure(.cannotOpen(result), stage: "write-overlay-control"); return }
            }
            sentQRCode = qrCode
            didSendQRCode = true
        }
        let retained = Unmanaged.passRetained(output)
        let result = CMSimpleQueueEnqueue(bufferQueue, element: retained.toOpaque())
        if result != noErr {
            retained.release()
            recordFailure(.cannotOpen(result), stage: "enqueue-frame")
        } else {
            health.sentFrame()
            lastFailureStage = nil
            status = .sending
        }
    }

    func stop() {
        lock.lock()
        pending = nil
        lock.unlock()
        worker.sync { self.stopOnWorker() }
    }

    private func stopOnWorker(preserveCapture: Bool = false) {
        if device != 0, stream != 0 {
            Self.logger.notice("Closing sink device=\(self.device, privacy: .public) stream=\(self.stream, privacy: .public)")
            let result = CMIODeviceStopStream(device, stream)
            Self.logger.info("Sink stopped device=\(self.device, privacy: .public) stream=\(self.stream, privacy: .public) code=\(result, privacy: .public)")
        }
        if let bufferQueue {
            while let pointer = CMSimpleQueueDequeue(bufferQueue) {
                Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release()
            }
        }
        bufferQueue = nil
        queueIsFull = false
        inputFormat = nil
        renderer = nil
        sentQRCode = nil
        didSendQRCode = false
        device = 0
        stream = 0
        lastProbe = 0
        health.reset()
        if !preserveCapture { health.expectsFrames = false }
        lastFailureStage = nil
        status = preserveCapture ? .connecting : health.status(isInstalled: !observedDevices.isEmpty, supportsDemand: supportsDemand)
    }

    private func connect(format inputFormat: VideoFormat) {
        for id in matchingDeviceIDs() {
            let streams = objectIDs(id, selector: kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeOutput)
            guard let sink = streams.first else {
                recordFailure(.cannotOpen(OSStatus(kCMIOHardwareBadStreamError)), stage: "find-sink")
                continue
            }
            let descriptions = formatDescriptions(sink)
            let formats = descriptions.map { description -> VideoFormat in
                let size = CMVideoFormatDescriptionGetDimensions(description)
                return VideoFormat(width: Int(size.width), height: Int(size.height))
            }
            guard let selected = inputFormat.bestMatch(in: formats), let index = formats.firstIndex(of: selected),
                  let renderer = try? VideoFrameRenderer(format: selected) else {
                recordFailure(.cannotOpen(OSStatus(kCMIOHardwareUnsupportedOperationError)), stage: "negotiate-format")
                return
            }
            // Negotiate before starting the sink, including when capture changes size.
            // Read the installed extension's list so an older 720p extension still works.
            Self.logger.info("Opening sink device=\(id, privacy: .public) stream=\(sink, privacy: .public) format=\(selected.width, privacy: .public)x\(selected.height, privacy: .public)")
            var description = Unmanaged.passUnretained(descriptions[index])
            var property = address(kCMIOStreamPropertyFormatDescription)
            let formatResult = CMIOObjectSetPropertyData(sink, &property, 0, nil,
                UInt32(MemoryLayout.size(ofValue: description)), &description)
            guard formatResult == noErr else {
                recordFailure(.cannotOpen(formatResult), stage: "set-format")
                return
            }
            var unmanagedQueue: Unmanaged<CMSimpleQueue>?
            let queueResult = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
            guard queueResult == noErr, let queue = unmanagedQueue?.takeRetainedValue() else {
                recordFailure(.cannotOpen(queueResult), stage: "copy-buffer-queue")
                return
            }
            let startResult = CMIODeviceStartStream(id, sink)
            guard startResult == noErr else {
                recordFailure(.cannotStart(startResult), stage: "start-sink")
                return
            }
            device = id
            stream = sink
            bufferQueue = queue
            self.inputFormat = inputFormat
            self.renderer = renderer
            Self.logger.notice("Sink opened; waiting for first frame")
            status = .connecting
            return
        }
        status = .notInstalled
    }

    private func recordFailure(_ failure: VirtualCameraStatus, stage: String) {
        if health.failure != failure || lastFailureStage != stage {
            Self.logger.error("Sink failure stage=\(stage, privacy: .public) code=\(failure.errorCode ?? 0, privacy: .public) status=\(failure.message, privacy: .public)")
        }
        lastFailureStage = stage
        health.failed(failure)
        status = failure
    }

    private func formatDescriptions(_ stream: CMIOStreamID) -> [CMFormatDescription] {
        var property = address(kCMIOStreamPropertyFormatDescriptions)
        var value: Unmanaged<CFArray>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &property, 0, nil,
            UInt32(MemoryLayout.size(ofValue: value)), &used, &value) == noErr,
            let descriptions = value?.takeRetainedValue() as? [CMFormatDescription] else { return [] }
        return descriptions.filter {
            CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video &&
            CMFormatDescriptionGetMediaSubType($0) == kCVPixelFormatType_32BGRA
        }
    }

    private func matchingDeviceIDs() -> [CMIODeviceID] {
        objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices).filter { id in
            var property = address(kCMIODevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let result = CMIOObjectGetPropertyData(id, &property, 0, nil,
                UInt32(MemoryLayout.size(ofValue: uid)), &used, &uid)
            guard result == noErr, let value = uid?.takeRetainedValue() else { return false }
            return (value as String).caseInsensitiveCompare(VideoFormat.deviceID.uuidString) == .orderedSame
        }
    }

    private func address(_ selector: Int,
                         scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(scope), mElement: UInt32(kCMIOObjectPropertyElementMain))
    }

    private func objectIDs(_ object: CMIOObjectID, selector: Int,
                           scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
        var property = address(selector, scope: scope)
        var bytes: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let result = ids.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(object, &property, 0, nil, bytes, &used, buffer.baseAddress!)
        }
        return result == noErr ? Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size)) : []
    }
}
