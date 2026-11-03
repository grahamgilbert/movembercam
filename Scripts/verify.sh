#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/verification build/ModuleCache.noindex
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/VideoFrameRenderer.swift Shared/OverlayConfiguration.swift Shared/OverlayPreferences.swift Shared/FrameCompositor.swift \
  Tests/OverlayChecks.swift -o build/verification/OverlayChecks
build/verification/OverlayChecks "$PWD"
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/VideoFrameRenderer.swift CameraExtension/CameraProvider.swift \
  Tests/CameraExtensionChecks.swift -o build/verification/CameraExtensionChecks
build/verification/CameraExtensionChecks
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/VirtualCameraStatus.swift Shared/CameraExtensionUpgrade.swift \
  App/ExtensionInstaller.swift Tests/ExtensionUpgradeChecks.swift -o build/verification/ExtensionUpgradeChecks
build/verification/ExtensionUpgradeChecks
