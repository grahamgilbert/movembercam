import AppKit
import SystemExtensions

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var message = "Install once to use MovemberCam in Zoom."
    @Published var busy = false
    @Published var needsApproval = false
    @Published var needsAppRestart = false

    func install() {
        guard Bundle.main.object(forInfoDictionaryKey: "MovemberCamPreviewBuild") as? String != "YES" else {
            message = "This preview build can show your camera and overlay. Build with your Apple Developer team to install the Zoom camera; see README.md."
            return
        }
        guard Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" else {
            message = "Move MovemberCam.app to /Applications, open it there, then install the virtual camera."
            return
        }
        busy = true
        needsApproval = false
        needsAppRestart = false
        message = "Requesting camera installation…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VideoFormat.extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        guard Bundle.main.object(forInfoDictionaryKey: "MovemberCamPreviewBuild") as? String != "YES" else {
            message = "Use the signed app to remove an installed camera extension."
            return
        }
        busy = true
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VideoFormat.extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        needsApproval = true
        message = "Approve MovemberCam in System Settings → General → Login Items & Extensions → Camera Extensions."
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        busy = false
        needsApproval = false
        message = result == .willCompleteAfterReboot ? "Restart your Mac to finish changing the camera extension." :
            "Camera extension updated. Restart MovemberCam to connect to it, then reopen Zoom if needed."
        needsAppRestart = result == .completed
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        busy = false
        message = "\(error.localizedDescription) The app and camera extension must be signed by the same Apple Developer team."
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }
}
