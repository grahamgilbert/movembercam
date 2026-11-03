import CoreMediaIO
import Foundation
import os

/// A fresh process can distinguish stale app-local CMIO discovery from an unavailable extension.
/// This mode only reads device metadata; it never starts a stream or opens a physical camera.
enum CameraDiscoveryProbe {
    static let argument = "--probe-virtual-camera"
    private static let logger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "DiscoveryProbe")

    static func isCameraAvailable() -> Bool {
        var devicesProperty = address(kCMIOHardwarePropertyDevices)
        var bytes: UInt32 = 0
        let sizeResult = CMIOObjectGetPropertyDataSize(1, &devicesProperty, 0, nil, &bytes)
        guard sizeResult == noErr, bytes > 0 else {
            logger.notice("Fresh discovery has no devices code=\(sizeResult, privacy: .public)")
            return false
        }
        var devices = [CMIODeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        let result = devices.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(1, &devicesProperty, 0, nil, bytes, &used, $0.baseAddress!)
        }
        guard result == noErr else {
            logger.error("Fresh discovery failed code=\(result, privacy: .public)")
            return false
        }
        for device in devices.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size) {
            var property = address(kCMIODevicePropertyDeviceUID)
            var value: Unmanaged<CFString>?
            let read = CMIOObjectGetPropertyData(device, &property, 0, nil,
                UInt32(MemoryLayout.size(ofValue: value)), &used, &value)
            guard read == noErr, let uid = value?.takeRetainedValue(),
                  (uid as String).caseInsensitiveCompare(VideoFormat.deviceID.uuidString) == .orderedSame else { continue }
            logger.notice("Fresh discovery found virtual camera")
            return true
        }
        logger.notice("Fresh discovery did not find virtual camera")
        return false
    }

    static func run(completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [argument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Both completion paths serialize on main, including the timeout.
        var completed = false
        process.terminationHandler = { child in
            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true
                logger.notice("Fresh discovery probe exited code=\(child.terminationStatus, privacy: .public)")
                completion(child.terminationReason == .exit && child.terminationStatus == 0)
            }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !completed else { return }
                completed = true
                logger.error("Fresh discovery probe timed out")
                if process.isRunning { process.terminate() }
                completion(false)
            }
        } catch {
            completed = true
            logger.error("Could not start fresh discovery probe code=\((error as NSError).code, privacy: .public)")
            completion(false)
        }
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                  mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
}
