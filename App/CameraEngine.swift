import AVFoundation
import AppKit

struct CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPreview: (@MainActor (CMSampleBuffer) -> Void)?
    var onOutputStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "MovemberCam.capture", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "MovemberCam.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let compositor: FrameCompositor
    private let virtualCamera = VirtualCameraOutput()
    private var delivering = false
    private var previousFrameTime = -Double.infinity
    private let previewLock = NSLock()
    private var pendingPreview: CMSampleBuffer?
    private var previewScheduled = false
    private var observers: [NSObjectProtocol] = []

    init(configuration: OverlayConfiguration) throws {
        let logoURL = Bundle.main.url(forResource: "MovemberMo", withExtension: "png")
        let logo = logoURL.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        compositor = try FrameCompositor(configuration: configuration, logo: logo)
        super.init()
        virtualCamera.onStatus = { [weak self] status in self?.onOutputStatus?(status) }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.onFailure?(error?.localizedDescription ?? "Camera capture stopped unexpectedly.")
            })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
            object: session, queue: nil) { [weak self] _ in
                self?.onFailure?("The camera was interrupted. Try starting it again.")
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)

    static func cameras() -> [CameraChoice] {
        discoverySession.devices.filter {
            $0.uniqueID.caseInsensitiveCompare(VideoFormat.deviceID.uuidString) != .orderedSame &&
            $0.localizedName != VideoFormat.cameraName
        }.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var virtualCameraAvailable: Bool {
        discoverySession.devices.contains {
            $0.uniqueID.caseInsensitiveCompare(VideoFormat.deviceID.uuidString) == .orderedSame
        }
    }

    func configure(_ configuration: OverlayConfiguration, completion: @escaping (Error?) -> Void) {
        frameQueue.async {
            do {
                try self.compositor.configure(configuration)
                if !self.delivering { self.showPlaceholderOnFrameQueue() }
                completion(nil)
            } catch { completion(error) }
        }
    }

    func showPlaceholder() { frameQueue.async { self.showPlaceholderOnFrameQueue() } }

    func setOverlayEnabled(_ enabled: Bool) {
        frameQueue.async {
            self.compositor.isOverlayEnabled = enabled
            if !self.delivering { self.showPlaceholderOnFrameQueue() }
        }
    }

    private func showPlaceholderOnFrameQueue() {
        if let sample = try? compositor.render(nil, at: CMClockGetTime(CMClockGetHostTimeClock())) {
            publishPreview(sample)
        }
    }

    private func publishPreview(_ sample: CMSampleBuffer) {
        previewLock.lock()
        pendingPreview = sample
        guard !previewScheduled else { previewLock.unlock(); return }
        previewScheduled = true
        previewLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewLock.lock()
            let latest = self.pendingPreview
            self.pendingPreview = nil
            self.previewScheduled = false
            self.previewLock.unlock()
            if let latest { self.onPreview?(latest) }
        }
    }

    func start(cameraID: String, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            do {
                guard let device = AVCaptureDevice(uniqueID: cameraID) else {
                    throw VideoError.message("That camera is disconnected. Choose another camera.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw VideoError.message("This camera cannot be opened. Close other apps using it and try again.")
                }
                self.session.addInput(input)
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(self.output) else {
                    self.session.removeInput(input)
                    self.session.commitConfiguration()
                    throw VideoError.message("This camera does not support video output.")
                }
                self.session.addOutput(self.output)
                if let connection = self.output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                self.session.commitConfiguration()
                // Some cameras cannot produce exactly 30 fps; the frame queue limits the output rate.
                if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    if (try? device.lockForConfiguration()) != nil {
                        device.activeVideoMinFrameDuration = VideoFormat.duration
                        device.activeVideoMaxFrameDuration = VideoFormat.duration
                        device.unlockForConfiguration()
                    }
                }
                self.frameQueue.sync { self.delivering = true; self.previousFrameTime = -Double.infinity }
                self.session.startRunning()
                guard self.session.isRunning else { throw VideoError.message("The camera did not start.") }
                completion(nil)
            } catch {
                self.frameQueue.sync { self.delivering = false; self.virtualCamera.stop() }
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                self.session.commitConfiguration()
                completion(error)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            self.frameQueue.sync { self.delivering = false; self.virtualCamera.stop() }
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.session.commitConfiguration()
            self.frameQueue.async { self.showPlaceholderOnFrameQueue(); completion?() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard delivering, let input = sampleBuffer.imageBuffer else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        guard time.seconds - previousFrameTime >= 1.0 / 30.0 - 0.002 else { return }
        previousFrameTime = time.seconds
        do {
            let sample = try compositor.render(input, at: time)
            virtualCamera.send(sample)
            publishPreview(sample)
        } catch {
            // A full buffer pool means consumers are behind: drop this frame instead of blocking capture.
            if case VideoError.operation(_, kCVReturnWouldExceedAllocationThreshold) = error { return }
            delivering = false
            onFailure?(error.localizedDescription)
        }
    }
}
