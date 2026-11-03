/// Relaunch restores Settings; live virtual-camera demand alone controls capture.
struct LaunchBehavior {
    let showSettings: Bool

    init(arguments: [String], launchedAtLogin: Bool) {
        showSettings = !launchedAtLogin || arguments.contains("--show-settings")
    }

    static func restartArguments() -> [String] {
        ["--show-settings"]
    }

    /// Start the new process only after the old instance has exited. Opening a
    /// second instance first can leave restored SwiftUI windows hidden on macOS.
    static func relaunchArguments(processID: Int32, applicationPath: String) -> [String] {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
        shift
        app_path="$1"
        shift
        exec /usr/bin/open -n "$app_path" --args "$@"
        """
        return ["-c", script, "MovemberCam relaunch", String(processID), applicationPath] +
            restartArguments()
    }

}
