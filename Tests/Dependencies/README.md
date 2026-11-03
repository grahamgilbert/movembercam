# Sparkle installation checks

The camera upgrade regression covers Sparkle 2.10.1's actual `SUPlainInstaller` and `SUFileManager`, including atomic app replacement, the fallback move path, nested camera extension payloads, and downgrade rejection. These tests create inert app bundles in temporary directories; they never install or activate a system extension.

Apply `Sparkle-2.10.1-camera-installation.patch` to a separate checkout of upstream tag `2.10.1` (commit `ab7d71291`). Then run:

```sh
xcodebuild -project Sparkle.xcodeproj -scheme Sparkle -destination 'platform=macOS' \
  '-only-testing:Sparkle Unit Tests/SUInstallerTest' \
  '-only-testing:Sparkle Unit Tests/SUFileManagerTest' \
  '-skip-testing:Sparkle Unit Tests/SUInstallerTest/testInstallIfRoot' \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

There are 13 relevant test cases: nine existing file handling tests and four camera bundle installation tests. The unrelated package installer test requires root and is excluded.

A real signed upgrade must also pass `Scripts/check-upgrade-test-driver.py DRIVER_APP HOST_APP`. An ad-hoc Sparkle CLI helper selects the different-team fallback installer, whereas MovemberCam's production helper is signed with the app's team and uses the atomic path. Use the production-signed Sparkle framework and matching signing identity in the driver. Preserve archive signature validation. The final native smoke test checks the running provider, source frames and QR decoding, preferences, and the Settings window after the complete updater flow.
