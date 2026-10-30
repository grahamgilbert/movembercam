/// Capture resumes only for an explicit in-app restart, never a login launch.
struct LaunchBehavior {
    let showSettings: Bool
    let resumeCamera: Bool

    init(arguments: [String], launchedAtLogin: Bool) {
        showSettings = !launchedAtLogin || arguments.contains("--show-settings")
        resumeCamera = !launchedAtLogin && arguments.contains("--resume-camera")
    }

    static func restartArguments(wasCapturing: Bool) -> [String] {
        ["--show-settings"] + (wasCapturing ? ["--resume-camera"] : [])
    }
}
