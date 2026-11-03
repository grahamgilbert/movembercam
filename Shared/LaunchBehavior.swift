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

    /// Start the new process only after the old instance has exited. Opening a
    /// second instance first can leave restored SwiftUI windows hidden on macOS.
    static func relaunchArguments(processID: Int32, applicationPath: String, wasCapturing: Bool) -> [String] {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
        shift
        app_path="$1"
        shift
        exec /usr/bin/open -n "$app_path" --args "$@"
        """
        return ["-c", script, "MovemberCam relaunch", String(processID), applicationPath] +
            restartArguments(wasCapturing: wasCapturing)
    }

}
