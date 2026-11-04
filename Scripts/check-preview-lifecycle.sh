#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Opt-in: briefly shows a native test window. No camera or notification access.
app="build/verification/PreviewLifecycleChecks.app"
mkdir -p "$app/Contents/MacOS" build/ModuleCache.noindex
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PreviewLifecycleChecks</string>
<key>CFBundleIdentifier</key><string>com.grahamgilbert.MovemberCam.PreviewLifecycleChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/OverlayConfiguration.swift Shared/OverlayPreferences.swift \
  Shared/VirtualCameraStatus.swift Shared/CameraControlState.swift Shared/CameraExtensionUpgrade.swift \
  Shared/CameraAttention.swift Shared/VideoAppRestartState.swift Shared/WindowLayout.swift Shared/LaunchBehavior.swift \
  App/AppModel.swift App/AppDelegate.swift App/CameraDiscoveryProbe.swift App/ExtensionInstaller.swift \
  App/CameraIssueNotifications.swift App/ZoomRestartTracker.swift App/CameraAttentionController.swift \
  App/LoginItemManager.swift App/NativeWindowStyle.swift App/SampleBufferPreview.swift App/MainWindow.swift \
  Tests/Support/CameraEngineStub.swift Tests/Support/PreviewServices.swift Tests/PreviewLifecycleChecks.swift \
  -o "$app/Contents/MacOS/PreviewLifecycleChecks"
"$app/Contents/MacOS/PreviewLifecycleChecks"
