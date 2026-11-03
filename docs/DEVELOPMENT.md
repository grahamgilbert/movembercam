# Building and development

Build from the repository root on a Mac with macOS 14 or later and Xcode 15 or later. The generated Xcode project is checked in. You need XcodeGen if you change `project.yml`; the build scripts regenerate the project when XcodeGen is installed.

For installing a downloaded release, see the [README](../README.md#install). For GitHub Actions, signing secrets, and publishing updates, see [CI and releases](RELEASING.md).

## Local preview

```sh
bash Scripts/build.sh preview
open build/Build/Products/Debug/MovemberCam.app
```

This creates an ad-hoc signed build for camera capture and local preview. It cannot install the virtual camera: preview builds omit the restricted installation entitlement. Installing the extension requires a paid Apple Developer team and the signing setup below.

## Signed development build

1. Open `MovemberCam.xcodeproj` in Xcode and add your Apple Developer account under **Settings → Accounts**.
2. Copy `Config/Signing.example.xcconfig` to `Config/Signing.xcconfig` and replace `YOURTEAMID` with your team ID. Both targets use that team and automatic signing. Use bundle identifiers registered to your team, enable the System Extension capability for the app identifier, and configure the extension's App Group.
3. Build the **MovemberCam** scheme in Xcode, or run:

   ```sh
   bash Scripts/build.sh signed
   ```

   The script may contact Apple to update provisioning profiles. To let Xcode register this Mac with your developer team, run:

   ```sh
   REGISTER_DEVELOPMENT_DEVICE=1 bash Scripts/build.sh signed
   ```

4. Quit any older running copy. Copy `build/Build/Products/Release/MovemberCam.app` to `/Applications`, then launch it and follow the [camera setup instructions](../README.md#install).

The app must run directly from `/Applications` to install the extension. When opened elsewhere, it offers **Move to Applications and Restart** or **Quit**. Moving preserves preferences and puts any replaced copy in Trash. A failed move must be retried before the app can continue.

If you change bundle identifiers, update `project.yml`, `Shared/VideoFormat.swift` (`extensionIdentifier`), and the App Group in `Config/Extension.entitlements`. Keep the App Group prefixed by the extension's Mach service name. The app and extension must be signed by the same team; device and stream UUIDs can remain unchanged.

## Build a DMG

Distribution builds require Xcode, Python 3.10 or later, `Config/Signing.xcconfig`, and a valid **Developer ID Application** signing identity.

```sh
bash Scripts/build-dmg.sh
```

The script archives the app, exports the app and camera extension with Developer ID signing, and creates a versioned DMG and SHA-256 checksum in `dist/`. Without a notarization option, the DMG is signed but not notarized.

Python packaging dependencies are pinned in `Scripts/dmg-requirements.txt` and installed into `build/dmg-tools`. The script uses `dmgbuild` to set the Finder layout without Automation permission. The first run downloads dependencies; signing and provisioning may also contact Apple.

### Notarization

To notarize and staple the DMG using an existing `notarytool` keychain profile:

```sh
bash Scripts/build-dmg.sh --notarize YOUR_KEYCHAIN_PROFILE
```

To use the developer account already signed into Xcode:

```sh
bash Scripts/build-dmg.sh --notarize-xcode
```

The Xcode option submits the app to Apple, staples the ticket to the app, checks Gatekeeper acceptance, and packages it inside a signed DMG. The `--notarize PROFILE` option submits and staples the DMG itself.

### Package an existing app

```sh
bash Scripts/build-dmg.sh --app /path/to/MovemberCam.app --output dist/MovemberCam.dmg
```

This preserves the input app's signing. A development-signed app remains a development build; use the default archive/export path and notarization for distribution to other Macs. The local preview build cannot serve as a virtual-camera installer.

### Installer artwork

`Scripts/RenderAppIcon.swift` generates the app icon before archiving. `Scripts/RenderDMGBackground.swift` draws the installer background; `Scripts/DMGSettings.py` sets icon positions and the Finder layout.

## Verification

```sh
swift test
python3 -m unittest discover -s Tests/Signing -v
bash Scripts/verify.sh
```

The checks cover settings validation and persistence, signing, capture-mode selection, and video composition. Video checks render synthetic frames with the production compositor, decode the QR code at 720p and 360p using Vision, recognize the written URL, and verify mirroring and overlay bypass. They also switch between 1080p, 1440p, 4K, 4:3, and a nonstandard camera resolution, checking both overlay positions, sample format descriptions, and conversion to a meeting-app resolution. Sample frames are saved in `build/verification/`. Synthetic camera-extension checks exercise the real property handlers for default resolution, meeting negotiation, camera switching, consumer demand, and invalid format changes without installing the extension or opening a camera. A controlled engine also exercises the production app model through demand changes, asynchronous start/stop, permission requests, disconnection, capture failures, and extension replacement.

End-to-end testing requires an installed, approved camera extension and two participants or devices. In a call, scan the received QR code, check the written URL and logo, toggle the overlay, and switch physical cameras. Confirm that selecting MovemberCam opens the physical camera, closing the last consumer releases it, and quitting the app clears the feed. Also test two simultaneous consumers, closing a consumer during camera startup, camera switching, permission denial and later approval, and extension replacement during a call.

## Architecture

| Component | Role |
| --- | --- |
| `App/CameraEngine.swift` | Captures the selected camera with AVFoundation. |
| `Shared/FrameCompositor.swift` | Caches the logo, QR code, and text overlay, then composites it with camera frames using Core Image. |
| `App/VirtualCameraOutput.swift` | Sends the composited frames to the camera extension's CoreMediaIO sink stream. |
| `CameraExtension/CameraProvider.swift` | Publishes the source stream that video apps discover as MovemberCam. |

The preview displays the same composited video through `AVSampleBufferDisplayLayer`. Virtual-camera discovery and delivery run on a separate worker queue. Both the preview and virtual output retain only the newest pending frame, dropping older frames to prevent growing latency.

Auto resolution selects the largest camera video mode up to 3840 × 2160 that supports 30 fps. If no mode supports exactly 30 fps, it prefers the nearest supported rate, then resolution. Capture output is capped at 30 fps. The compositor reads the actual incoming frame dimensions, rebuilds its buffers and overlay when they change, and preserves the camera's aspect ratio. Overlay dimensions and margins scale proportionally; QR modules stay aligned to whole output pixels.

The extension advertises a fixed list of common 16:9 and 4:3 formats through 4K. Before starting the sink, the app reads the installed extension's formats and selects an exact resolution match where available, otherwise the closest aspect ratio without increasing resolution when possible. This also permits a new app to feed an older 720p extension. The source defaults to the sink's resolution while no meeting is using it. Once a meeting selects a source format, the extension keeps that output size when cameras change and scales frames as needed. Aspect-ratio conversions add borders to retain the whole QR card and branding. In-process pixel-buffer attachments carry the QR URL and drawing area. Because CMIO drops those attachments across processes, the app sends timestamped QR changes through the sink’s custom `mqrc` control property. The extension associates each change with queued frame timestamps. Each converter redraws the QR at an integer module size on its final pixel grid and caches the artwork until its URL or layout changes. At small letterboxed sizes, the QR drawing area grows enough to retain a one-pixel module and four-module white margin. Bypassed and idle frames clear QR reconstruction. Updating the extension and reopening the meeting app is required to expose the new formats to an existing installation.

The extension exposes a read-only `mdem` source-stream property indicating whether any meeting consumer is streaming. The app checks it every half second, including while physical capture and its sink stream are stopped. Sink activity never creates demand. Opening Settings or launching at login does not itself open the camera; an already active video app does. Selecting MovemberCam in a video app’s settings preview also counts as use. The last consumer stopping releases capture and clears the preview. Camera permission can be granted before a consumer connects, or is requested on first use. Failed capture waits for a new consumer session, a source change, or **Refresh Cameras** before retrying.

Older extensions without `mdem` report that an update is needed and leave the physical camera off. Build 9 lets the existing extension upgrade flow replace earlier builds. Extension replacement suspends capture until installation leaves its blocking state; current demand then controls whether it resumes. The obsolete `--resume-camera` launch flag no longer opens hardware.

Switching cameras during capture stops the old source and resumes with the new one. The extension sends an empty dark frame at the negotiated output resolution when capture stops or no fresh frame arrives for half a second. Audio stays with the microphone selected in the meeting app.

Overlay settings are stored locally in macOS preferences. **Apply Changes** saves the URLs, QR position, and mirroring; unapplied edits are discarded when the app quits. Camera selection and the menu bar overlay toggle save immediately. Opening Settings brings the existing window forward.

Sparkle checks for signed updates every hour when automatic checks are enabled. Prerelease updates are optional. Update feeds and downloads come from this repository; video rendering and QR generation happen locally.

References: [Apple camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), [WWDC Core Media I/O overview](https://developer.apple.com/videos/play/wwdc2022/10022/), and [Movember fundraising assets](https://uk.movember.com/support-us/workplace-fundraising-assets).

### Extension upgrades

On launch from Applications, signed builds query SystemExtensions for installed versions of the bundled camera extension. Older enabled versions are activated automatically; a first installation and a deliberately disabled extension remain user choices. Removed versions awaiting reboot are ignored when choosing the active version, and the app does not downgrade a newer installed extension.

Capture stops before replacement. Activation completion starts a bounded CoreMediaIO availability check rather than immediately reporting success. A missing device triggers one registration retry after ten seconds; another ten seconds without discovery offers Restart MovemberCam. The Virtual Camera settings show one recovery action at a time; if an app restart has already been tried, the next action opens System Settings. Physical capture resumes only if the discovered extension reports consumer demand. The restart helper waits for the old app process to exit before reopening it, so its CMIO connection is fresh and SwiftUI windows reopen reliably. Approval, reboot-required results, validation failures, and removal have distinct UI states. Errors remain visible when an older device is still discoverable. Signed distribution builds must be notarized; development signing can be used for local extension testing without changing macOS security settings.

`Tests/ExtensionUpgradeChecks.swift` runs the production installer with inert SystemExtensions requests and a controlled scheduler, covering activation/discovery ordering, approval, retries, stale callbacks, validation failures, and removal. `CameraExtensionUpgradeTests` covers version selection and disabled/removal policies. Live testing still requires updating the installed extension and checking the camera from another process.

### Live transport check

Normal CI runs the synthetic video/QR checks, stream-property checks, and controlled installer tests through `Scripts/verify.sh`. They need macOS frameworks but no physical camera or installed extension. The live checker below also uses synthetic camera pixels, but requires a signed, installed, approved extension; use it manually or on a Mac runner configured for extension testing. Quit MovemberCam before running the default writer test, and close other apps consuming the virtual camera so they do not renegotiate its source format during the test.

```sh
swiftc -swift-version 5 -module-cache-path build/ModuleCache.noindex \
  Shared/VideoFormat.swift Shared/VideoFrameRenderer.swift \
  Shared/OverlayConfiguration.swift Shared/FrameCompositor.swift \
  Scripts/LiveCameraChecks.swift -o build/verification/LiveCameraChecks
build/verification/LiveCameraChecks
build/verification/LiveCameraChecks --480
```

The checker sends a 220-byte QR link at 1080p through the real CMIO sink and decodes the negotiated 360p or 480p source frames with Vision. It fails when no QR decodes. It does not save frames or open the physical camera. Use `--inspect` to inspect formats, or `--read-only --360 --long` while MovemberCam captures with the checker’s synthetic long URL to test the physical-camera path. After testing, `--reset720` returns source and sink to their default format for compatibility with older apps. Physical camera discovery and capture still require a separate smoke test.
