/// Relaunch restores Settings; current preview and virtual-camera demand control capture.
struct LaunchBehavior {
    let showSettings: Bool

    init(arguments: [String], launchedAtLogin: Bool) {
        showSettings = arguments.contains("--show-settings") ||
            (!launchedAtLogin && !arguments.contains("--hide-settings"))
    }

    static func restartArguments() -> [String] {
        ["--show-settings"]
    }

    /// Start the new process only after the old instance has exited. Opening a
    /// second instance first can leave restored SwiftUI windows hidden on macOS.
    static func relaunchArguments(processID: Int32, applicationPath: String,
                                 showSettings: Bool = true, activates: Bool = true,
                                 cameraRecovery: Bool = false) -> [String] {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
        shift
        app_path="$1"
        shift
        activation="$1"
        shift
        if [ "$activation" = "background" ]; then
            exec /usr/bin/open -g -n "$app_path" --args "$@"
        fi
        exec /usr/bin/open -n "$app_path" --args "$@"
        """
        var flags = [showSettings ? "--show-settings" : "--hide-settings"]
        if !activates { flags.append("--background-recovery") }
        if cameraRecovery { flags.append("--camera-recovery") }
        return ["-c", script, "MovemberCam relaunch", String(processID), applicationPath,
                activates ? "foreground" : "background"] + flags
    }

}
