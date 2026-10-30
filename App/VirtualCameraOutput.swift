import CoreMediaIO
import Foundation

/// CoreMediaIO work runs on its own serial queue. Capture hands off just the latest frame.
final class VirtualCameraOutput {
    var onStatus: ((String) -> Void)?
    private let worker = DispatchQueue(label: "MovemberCam.virtualOutput", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: CMSampleBuffer?
    private var scheduled = false
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var lastProbe: CFAbsoluteTime = 0
    private var deviceListener: CMIOObjectPropertyListenerBlock?
    private var status = "Virtual camera idle" {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    init() {
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.lastProbe = 0 }
        deviceListener = listener
        var property = address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, worker, listener)
    }

    deinit {
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
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProbe > 1 {
            lastProbe = now
            if device != 0 {
                var alive: UInt32 = 0
                var address = address(kCMIODevicePropertyDeviceIsAlive)
                var used: UInt32 = 0
                let result = CMIOObjectGetPropertyData(device, &address, 0, nil,
                    UInt32(MemoryLayout.size(ofValue: alive)), &used, &alive)
                if result != noErr || alive == 0 { stopOnWorker() }
            }
            if bufferQueue == nil { connect() }
        }
        guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - sample.presentationTimeStamp.seconds < 0.25,
              let bufferQueue, CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else { return }
        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(bufferQueue, element: retained.toOpaque()) != noErr {
            retained.release()
        }
    }

    func stop() {
        lock.lock()
        pending = nil
        lock.unlock()
        worker.sync { self.stopOnWorker() }
    }

    private func stopOnWorker() {
        if device != 0, stream != 0 { CMIODeviceStopStream(device, stream) }
        if let bufferQueue {
            while let pointer = CMSimpleQueueDequeue(bufferQueue) {
                Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release()
            }
        }
        bufferQueue = nil
        device = 0
        stream = 0
        lastProbe = 0
        status = "Virtual camera idle"
    }

    private func connect() {
        for id in objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
            var property = address(kCMIODevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let result = CMIOObjectGetPropertyData(id, &property, 0, nil,
                UInt32(MemoryLayout.size(ofValue: uid)), &used, &uid)
            guard result == noErr, let value = uid?.takeRetainedValue(),
                  (value as String).caseInsensitiveCompare(VideoFormat.deviceID.uuidString) == .orderedSame else { continue }
            let streams = objectIDs(id, selector: kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeOutput)
            guard let sink = streams.first else { continue }
            var unmanagedQueue: Unmanaged<CMSimpleQueue>?
            let queueResult = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
            guard queueResult == noErr, let queue = unmanagedQueue?.takeRetainedValue() else {
                status = "Cannot open virtual camera (\(queueResult))"
                return
            }
            let startResult = CMIODeviceStartStream(id, sink)
            guard startResult == noErr else {
                status = startResult == -4 ? "Virtual camera rejected the connection" : "Cannot start virtual camera (\(startResult))"
                return
            }
            device = id
            stream = sink
            bufferQueue = queue
            status = "Sending to MovemberCam"
            return
        }
        status = "Virtual camera not installed"
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
