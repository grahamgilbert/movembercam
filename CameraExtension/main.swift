import CoreMediaIO
import Foundation
import os

let source = CameraProvider()
do {
    try source.setUp()
    CMIOExtensionProvider.startService(provider: source.provider)
    CFRunLoopRun()
} catch {
    Logger(subsystem: VideoFormat.extensionIdentifier, category: "startup")
        .fault("Unable to start virtual camera: \(error.localizedDescription, privacy: .public)")
    exit(EXIT_FAILURE)
}
