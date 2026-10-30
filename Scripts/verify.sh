#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/verification build/ModuleCache.noindex
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/OverlayConfiguration.swift Shared/OverlayPreferences.swift Shared/FrameCompositor.swift \
  Tests/OverlayChecks.swift -o build/verification/OverlayChecks
build/verification/OverlayChecks "$PWD"
