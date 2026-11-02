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

The checks cover settings validation and persistence, signing, capture-mode selection, and video composition. Video checks render synthetic frames with the production compositor, decode the QR code at 720p and 360p using Vision, recognize the written URL, and verify mirroring and overlay bypass. They also switch between 1080p, 1440p, 4K, 4:3, and a nonstandard camera resolution, checking both overlay positions, sample format descriptions, and conversion to a meeting-app resolution. Sample frames are saved in `build/verification/`. Synthetic camera-extension checks exercise the real property handlers for default resolution, meeting negotiation, camera switching, and invalid format changes without installing the extension or opening a camera.

End-to-end testing requires an installed, approved camera extension and two participants or devices. In a call, scan the received QR code, check the written URL and logo, toggle the overlay, and switch physical cameras. Confirm that stopping capture or quitting the app clears the feed.

## Architecture

| Component | Role |
| --- | --- |
| `App/CameraEngine.swift` | Captures the selected camera with AVFoundation. |
| `Shared/FrameCompositor.swift` | Caches the logo, QR code, and text overlay, then composites it with camera frames using Core Image. |
| `App/VirtualCameraOutput.swift` | Sends the composited frames to the camera extension's CoreMediaIO sink stream. |
| `CameraExtension/CameraProvider.swift` | Publishes the source stream that video apps discover as MovemberCam. |

The preview displays the same composited video through `AVSampleBufferDisplayLayer`. Virtual-camera discovery and delivery run on a separate worker queue. Both the preview and virtual output retain only the newest pending frame, dropping older frames to prevent growing latency.

Auto resolution selects the largest camera video mode up to 3840 × 2160 that supports 30 fps. If no mode supports exactly 30 fps, it prefers the nearest supported rate, then resolution. Capture output is capped at 30 fps. The compositor reads the actual incoming frame dimensions, rebuilds its buffers and overlay when they change, and preserves the camera's aspect ratio. Overlay dimensions and margins scale proportionally; QR modules stay aligned to whole output pixels.

The extension advertises a fixed list of common 16:9 and 4:3 formats through 4K. Before starting the sink, the app reads the installed extension's formats and selects an exact resolution match where available, otherwise the closest aspect ratio without increasing resolution when possible. This also permits a new app to feed an older 720p extension. The source defaults to the sink's resolution while no meeting is using it. Once a meeting selects a source format, the extension keeps that output size when cameras change and scales frames as needed. Aspect-ratio conversions add borders to retain the whole QR card and branding. Updating the extension and reopening the meeting app is required to expose the new formats to an existing installation.

Switching cameras during capture stops the old source and resumes with the new one. The extension sends an empty dark frame at the negotiated output resolution when capture stops or no fresh frame arrives for half a second. Audio stays with the microphone selected in the meeting app.

Overlay settings are stored locally in macOS preferences. **Apply Changes** saves the URLs, QR position, and mirroring; unapplied edits are discarded when the app quits. Camera selection and the menu bar overlay toggle save immediately. Opening Settings brings the existing window forward.

Sparkle checks for signed updates every hour when automatic checks are enabled. Prerelease updates are optional. Update feeds and downloads come from this repository; video rendering and QR generation happen locally.

References: [Apple camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), [WWDC Core Media I/O overview](https://developer.apple.com/videos/play/wwdc2022/10022/), and [Movember fundraising assets](https://uk.movember.com/support-us/workplace-fundraising-assets).
