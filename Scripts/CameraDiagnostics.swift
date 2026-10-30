import AVFoundation
import CoreMediaIO
import Foundation

func address(_ selector: Int, _ scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(scope), mElement: UInt32(kCMIOObjectPropertyElementMain))
}
func ids(_ object: CMIOObjectID, _ selector: Int, _ scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
    var property = address(selector, scope)
    var size: UInt32 = 0
    let query = CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size)
    guard query == noErr else { print("Property size status: \(query)"); return [] }
    guard size > 0 else { return [] }
    var values = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    let result = values.withUnsafeMutableBytes {
        CMIOObjectGetPropertyData(object, &property, 0, nil, size, &used, $0.baseAddress!)
    }
    guard result == noErr else { print("Property read status: \(result)"); return [] }
    return Array(values.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
}
func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &used, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}
func inspect(_ label: String) {
    let devices = ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
    print("\(label): \(devices.count) CMIO devices")
    for device in devices {
        let name = string(device, kCMIOObjectPropertyName) ?? "(unknown)"
        guard name.contains("Movember") else { continue }
        print("Device \(device): \(name), UID: \(string(device, kCMIODevicePropertyDeviceUID) ?? "nil")")
        for (label, scope) in [("global", kCMIOObjectPropertyScopeGlobal), ("input", kCMIODevicePropertyScopeInput), ("output", kCMIODevicePropertyScopeOutput)] {
            let streams = ids(device, kCMIODevicePropertyStreams, scope)
            print("  \(label) streams: \(streams)")
            for stream in streams {
                var property = address(kCMIOStreamPropertyDirection)
                var direction: UInt32 = 999
                var used: UInt32 = 0
                let status = CMIOObjectGetPropertyData(stream, &property, 0, nil, 4, &used, &direction)
                print("    stream \(stream) direction \(direction), status \(status)")
            }
        }
    }
}

let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
for device in discovery.devices where device.localizedName.contains("Movember") {
    print("AVFoundation: \(device.localizedName), UID: \(device.uniqueID)")
}
inspect("Default discovery")
