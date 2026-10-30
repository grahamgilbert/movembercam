# MovemberCam

A native macOS app that adds your fundraising QR code, the official Movember Mo, and a written URL to a real camera feed. Select **MovemberCam** as your camera in Zoom or another video app.

Requires macOS 14 or later and Xcode 15 or later. There are no third-party runtime dependencies.

For automated builds, signing secrets, notarization, and publishing versioned GitHub releases, see [CI and releases](docs/RELEASING.md).

When launched outside `/Applications`, the app offers **Move to Applications and Restart** or **Quit**. Moving installs this copy in `/Applications`, preserves preferences, and keeps any replaced copy in Trash. If the copy fails, retry or quit; the app does not continue from the unsupported location.

## What it does

- Select a built-in, USB, or Continuity Camera. Changing cameras during capture automatically stops the old source and resumes with the new one.
- Configure the QR destination and written URL independently; settings persist between launches.
- Preview the actual composited frames sent to the virtual camera, at 1280 × 720 and up to 30 fps.
- Use the moustache menu bar icon to **Enable overlay**, start/stop the camera, reopen settings, or quit. MovemberCam runs as a menu bar app without a Dock icon. Disabling the overlay keeps the camera feed running. Closing the settings window keeps the app running in the menu bar.
- A first-run setup guide walks through camera access, installation, Zoom selection with actual settings screenshots, and checking the received QR code. Reopen it from Help → MovemberCam Setup Guide, the menu bar, or the settings window. Guide progress is saved; finishing requires confirming the Zoom/QR check and detecting the installed camera.
- Choose **Open at Login** during setup or later under **Startup** in settings. This uses macOS Login Items and stays off until you opt in. Launching the app does not automatically start camera capture.
- Position the QR card at the bottom left or right. Mirror only the physical camera image; the QR and text stay readable.
- Stop capture to release the physical camera. The extension sends an empty dark frame when the app stops or stops delivering fresh frames for half a second.

Both URLs default to `https://movember.com/t/musta-ch`. Press **Apply Changes** after editing settings to save the URLs, QR position and mirroring in macOS preferences; applied settings survive quitting and relaunching. The menu bar overlay toggle and camera selection save immediately, without applying other edits. Unapplied overlay edits are not saved.

## Try the local preview

The generated Xcode project is included; XcodeGen is only needed if you change `project.yml`.

```sh
bash Scripts/build.sh preview
open build/Build/Products/Debug/MovemberCam.app
```

This makes an ad-hoc signed build for local preview and camera capture. It **cannot install the virtual camera**. A paid Apple Developer team and proper signing/provisioning are needed to activate the camera extension. Preview builds omit the restricted installation entitlement.

## Enable the Zoom camera

1. Open `MovemberCam.xcodeproj` in Xcode. Add your Apple Developer account in Xcode Settings → Accounts.
2. Copy `Config/Signing.example.xcconfig` to `Config/Signing.xcconfig` and replace `YOURTEAMID` with your team ID. Both targets use that team and automatic signing. Enable the System Extension capability for the app identifier and provision the extension's App Group as needed. Use bundle identifiers registered to your team.
3. Build the **MovemberCam** scheme, or run `bash Scripts/build.sh signed`. That command may contact Apple's signing service to update provisioning profiles. If this Mac needs to be registered with your developer team, explicitly opt in with `REGISTER_DEVELOPMENT_DEVICE=1 bash Scripts/build.sh signed`.
4. Copy the resulting **signed** `MovemberCam.app` from `build/Build/Products/Release` into `/Applications`, and launch it from there. Quit any older running copy first.
5. Click **Install camera**. Approve the extension when macOS prompts you. On recent macOS versions, look in System Settings → General → Login Items & Extensions → Camera Extensions. Follow the macOS prompt if its location differs.
6. Select your physical camera, set your links, apply the overlay, and click **Start camera**.
7. Restart Zoom if necessary, then choose **MovemberCam** in its camera picker. Keep MovemberCam running during calls. Zoom's mirrored self-view may reverse the text locally; the transmitted pixels are readable for participants.

If you change bundle identifiers, update `project.yml`, `Shared/VideoFormat.swift` (`extensionIdentifier`), and the extension's App Group in `Config/Extension.entitlements`. Keep the App Group prefixed by the extension's Mach service name. The app and extension must be signed by the same team. The device/stream UUIDs can remain stable.

Choose Camera → **Remove Virtual Camera** to uninstall the extension while capture is stopped. Use **Quit MovemberCam** in the menu bar or ⌘Q to exit the app and release the camera.

For distribution to other Macs, use Developer ID signing and notarization for the app and embedded system extension; the local preview build is not a distributable installer.

## Build the drag-to-Applications DMG

```sh
bash Scripts/build-dmg.sh
```

The script archives the app, exports the app and camera extension with your team's **Developer ID Application** certificate, and builds `dist/MovemberCam-1.0.0.dmg` plus a portable SHA-256 checksum. The Finder window contains MovemberCam and an Applications shortcut, with a Retina background showing the official Mo and a drag arrow. The background is drawn at build time by `Scripts/RenderDMGBackground.swift`; icon positions and Finder layout are in `Scripts/DMGSettings.py`. `Scripts/RenderAppIcon.swift` generates the camera-and-moustache app icon at every macOS icon size before archiving.

Requires Xcode, Python 3.10+, `Config/Signing.xcconfig`, and a valid Developer ID Application signing identity. The script installs pinned Python packaging dependencies in an isolated `build/dmg-tools` environment and uses `dmgbuild` to write Finder metadata without controlling Finder or requesting Automation permission. Signing and provisioning may contact Apple; the first run also downloads those build dependencies.

To notarize for distribution, provide an existing `notarytool` keychain profile:

```sh
bash Scripts/build-dmg.sh --notarize YOUR_KEYCHAIN_PROFILE
```

This submits the signed DMG to Apple and staples the accepted notarization ticket. Without that option, the artifact is signed but not notarized.

Alternatively, use the developer account already signed into Xcode:

```bash
bash Scripts/build-dmg.sh --notarize-xcode
```

This submits the app through Xcode, staples Apple's ticket to the app, verifies Gatekeeper acceptance, and packages that notarized app inside the signed DMG. The `--notarize PROFILE` route notarizes and staples the DMG itself.

To package an existing signed app, or choose an output path:

```sh
bash Scripts/build-dmg.sh --app /path/to/MovemberCam.app --output dist/MovemberCam.dmg
```

The provided app's signing is preserved; a development-signed input remains a development build. Use the default archive/export path for Developer ID distribution builds.

## Verification

```sh
swift test
bash Scripts/verify.sh
```

The checks render synthetic camera frames using the production compositor, decode the QR code with Vision at 720p and 360p, recognize the written URL, verify mirror/bypass behavior, and check settings replacement/validation. A sample output frame is written to `build/verification/overlay.png`.

End-to-end virtual camera installation and Zoom testing require the signed/approved extension. Validate with two participants/devices: scan the received QR, confirm the written URL and logo, toggle the overlay from the menu bar while a call is live, switch physical cameras during capture, and verify that stopping/quitting the app clears the feed.

## Architecture

`App/CameraEngine.swift` captures the chosen device through AVFoundation. `Shared/FrameCompositor.swift` caches the logo/QR/text overlay and composites it with the live feed using Core Image. `App/VirtualCameraOutput.swift` enqueues those same frames into the camera extension's CoreMediaIO sink stream. `CameraExtension/CameraProvider.swift` publishes a source stream that meeting apps discover as MovemberCam. Queues are bounded; slow consumers drop frames instead of allowing capture latency to grow. Audio stays with the microphone selected in Zoom.

The preview displays video frames directly with `AVSampleBufferDisplayLayer`. Virtual-camera discovery and delivery run on a separate worker queue; the preview and virtual output each keep only the newest pending frame so a slow consumer cannot build up seconds of delay.

Video rendering and settings storage are local. The app performs no video uploads, analytics, or link requests. Your meeting app transmits the video when you use MovemberCam in a call.

References: [Apple camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), [WWDC Core Media I/O overview](https://developer.apple.com/videos/play/wwdc2022/10022/), and [official Movember fundraising assets](https://uk.movember.com/support-us/workplace-fundraising-assets).
