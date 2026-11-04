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

Built-in cameras use the AVFoundation high-quality session preset without overriding their active format. The video output requests BGRA pixels without specifying dimensions, so the preview and compositor preserve the input frame size. Other cameras use Auto resolution to select the largest video mode up to 3840 × 2160 that supports 30 fps. If no mode supports exactly 30 fps, it prefers the nearest supported rate, then resolution. Capture output is capped at 30 fps. The compositor reads the actual incoming frame dimensions, rebuilds its buffers and overlay when they change, and preserves the camera's aspect ratio. Overlay dimensions and margins scale proportionally; QR modules stay aligned to whole output pixels.

The extension advertises a fixed list of common 16:9 and 4:3 formats through 4K. Before starting the sink, the app reads the installed extension's formats and selects an exact resolution match where available, otherwise the closest aspect ratio without increasing resolution when possible. This also permits a new app to feed an older 720p extension. The source defaults to the sink's resolution while no meeting is using it. Once a meeting selects a source format, the extension keeps that output size when cameras change and scales frames as needed. Aspect-ratio conversions add borders to retain the whole QR card and branding. In-process pixel-buffer attachments carry the QR URL and drawing area. Because CMIO drops those attachments across processes, the app sends timestamped QR changes through the sink’s custom `mqrc` control property. The extension associates each change with queued frame timestamps. Each converter redraws the QR at an integer module size on its final pixel grid and caches the artwork until its URL or layout changes. At small letterboxed sizes, the QR drawing area grows enough to retain a one-pixel module and four-module white margin. Bypassed and idle frames clear QR reconstruction. Updating the extension and reopening the meeting app is required to expose the new formats to an existing installation.

The extension exposes a read-only `mdem` source-stream property indicating whether any meeting consumer is streaming. The app checks it every half second, including while physical capture and its sink stream are stopped. Sink activity never creates demand. Only the Camera and Overlay tabs request preview capture, and only while their window is visible and unoccluded. Switching to App, closing, hiding, minimizing, or fully covering Settings releases that request; external video consumers can still keep capture running. Login launch hides Settings before enabling preview demand. Selecting MovemberCam in a video app’s settings preview also counts as use. Capture stops when both the preview and the last external consumer are closed. Camera permission can be granted before a consumer connects, or is requested on first use. Failed capture waits for a new consumer session, a source change, or **Refresh Cameras** before retrying.

Older extensions without `mdem` report that an update is needed and cannot request capture for video apps; the Settings preview remains available. Build 9 lets the existing extension upgrade flow replace earlier builds. Extension replacement suspends capture until installation leaves its blocking state; current demand then controls whether it resumes. The obsolete `--resume-camera` launch flag no longer opens hardware.

A runtime capture failure stops the session and, while a preview or video consumer still needs it, refreshes cameras after one second. Automatic recovery is limited to one attempt per source and consumer session, including when the retry starts successfully but fails again later. A manual retry, source change, or new consumer session renews that attempt. Delayed recovery checks the capture generation, current demand, suspension, and shutdown before opening hardware. Startup failures do not schedule this delayed retry. A failed preview displays **Camera stopped** instead of suggesting that a video app is required.

Switching cameras during capture stops the old source and resumes with the new one. The extension sends an empty dark frame at the negotiated output resolution when capture stops or no fresh frame arrives for half a second. Audio stays with the microphone selected in the meeting app.

Overlay settings are stored locally in macOS preferences. **Apply Changes** saves the URLs, QR position, and mirroring; unapplied edits are discarded when the app quits. Camera selection and the menu bar overlay toggle save immediately. Opening Settings brings the existing window forward.

Sparkle checks for signed updates every hour when automatic checks are enabled. Prerelease updates are optional. Update feeds and downloads come from this repository; video rendering and QR generation happen locally.

References: [Apple camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), [WWDC Core Media I/O overview](https://developer.apple.com/videos/play/wwdc2022/10022/), and [Movember fundraising assets](https://uk.movember.com/support-us/workplace-fundraising-assets).

### Extension upgrades

On launch from Applications, signed builds query SystemExtensions for installed versions of the bundled camera extension. Older enabled versions are activated automatically; a first installation and a deliberately disabled extension remain user choices. Removed versions awaiting reboot are ignored when choosing the active version, and the app does not downgrade a newer installed extension.

Capture stops before replacement. Activation completion starts a bounded CoreMediaIO availability check rather than immediately reporting success. Activation completion resets the app’s sink connection while preserving physical capture and external consumers. After ten seconds without a usable connection, the app retries once. If the device is discoverable, it resets only the local sink connection. If no compatible device appears, it resubmits activation once to recover the macOS launch-job replacement race (`EALREADY` while the previous job is being removed). The retry count survives that activation callback; a second failed verification offers Restart MovemberCam instead of looping. Background status queries preserve an exhausted recovery state instead of restarting its timeout. The Virtual Camera settings expose **Retry Connection** directly for an unavailable device, with a separate app-restart fallback; these actions do not depend on a Camera application menu that accessory apps do not display. They show a primary recovery action and a read-only **Recheck Camera Status** action while approval or connection is unresolved; if an app restart has already been tried, the next action opens System Settings. Physical capture resumes for an open Settings preview or consumer demand reported by the discovered extension. The restart helper waits for the old app process to exit before reopening it, so its CMIO connection is fresh and SwiftUI windows reopen reliably. Approval, reboot-required results, validation failures, and removal have distinct UI states. Errors remain visible when an older device is still discoverable. Signed distribution builds must be notarized; development signing can be used for local extension testing without changing macOS security settings.

Approval waits do not show an installation spinner. On macOS 15 and later, the settings button uses the public Login Items navigation API; instructions explicitly name **Camera Extensions → MovemberCam Camera**, with **By Category** on macOS 26 and later. On macOS 14, approval uses Privacy & Security. A menu-bar-lifetime controller rechecks unresolved approval every five seconds, including while Settings is closed. Returning from System Settings or selecting **Recheck Camera Status** also queries installed extension properties even while an activation request is pending. These read-only queries never replace or duplicate the activation request. Each status check times out after ten seconds, preserving the activation and allowing another check; responses from timed-out checks are ignored. Enabled permission moves to a distinct activation-wait state; a missing completion offers app restart after ten seconds. A visible older camera cannot complete a pending update, and inspection errors or late responses cannot overwrite a completed activation. Historical pending approvals older than an enabled extension do not mask the enabled version.

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

### Camera attention and notifications

`CameraAttentionController` owns installer callbacks and status subscriptions for the lifetime of the menu bar app, independently of the Settings window. Extension approval, missing or failed installation, required restarts, physical camera permission, missing hardware, and capture failures have distinct messages and recovery actions. Extension problems take priority over physical camera problems. A warning badge on the mustache icon and the Settings banner stay visible through recovery until the camera is verified usable. Intentional extension removal clears its warning.

When no camera operation is in progress, an actionable issue requests notification permission if necessary and posts a Notification Center alert that opens MovemberCam Settings. Alerts are delivered and presented even while Settings is open or MovemberCam is in the foreground. The menu contains no warning title, instructions, or extra recovery row; detailed guidance lives in Settings. Notification permission denial or delivery failure leaves the persistent warning intact without a retry loop. Returning to the app after a denial rechecks notification permission, allowing an unresolved issue to alert once after notifications are enabled. The icon combines the mustache and warning badge in one template image. Delivered issue kinds are persisted until verified recovery so rechecks and app restarts do not repeat the same alert. The alert-delivery record uses a new version after 1.0.4 so an earlier suppressed banner cannot prevent the first corrected alert. A different issue can alert once; recovery clears delivered notifications and resets the policy. Pending authorization and delivery recheck current state to avoid stale alerts. General overlay validation errors are separate from capture failures.

`CameraAttentionTests` covers issue mapping and notification policy. `Tests/CameraAttentionChecks.swift` uses the production controller, AppModel, and installer with inert camera and notification adapters to check background monitoring, deduplication, recovery, notification taps during launch, denial, delivery failure, and delayed authorization. Signed smoke testing must still check macOS notification authorization/delivery and the real extension approval flow.

### Connection diagnostics

The app and extension use the unified logging subsystem `com.grahamgilbert.MovemberCam`, with `Lifecycle`, `ExtensionInstaller`, `VirtualOutput`, `Capture`, `CameraExtension`, and `Notifications` categories. State transitions, app/build/OS versions, installed extension versions and approval flags, activation request correlation tokens, verification cycle IDs, recovery attempts, first frame delivery, stream operations, queue stalls, and numeric errors are recorded. Unchanged polling is debug-level; repeated sink errors are deduplicated and extension consume errors are rate limited. Logs contain no camera frames, fundraising URLs, QR payloads, or physical camera names/unique IDs. Dynamic error descriptions are omitted; failure state names exclude their associated message.

Use Console with that subsystem filter, or collect recent records using:

```sh
log show --last 20m --style compact --info --debug --predicate 'subsystem == "com.grahamgilbert.MovemberCam"'
```

Discovery preserves an existing connection failure. When capture is active, the output remains connecting until a frame is successfully enqueued; seeing the device alone cannot report a successful stream. The half-second poll publishes discovery changes with Settings closed. `VirtualCameraConnectionHealth` and controlled installer checks cover failure retention, automatic reconnect after approval, bounded local retry, and repeated background queries after recovery is exhausted.

### Notification copy and icons

Notifications use a separate short title and one-sentence body, with full instructions confined to Settings. The app icon is compiled from `Resources/Assets.xcassets/AppIcon.appiconset`, using the existing camera/mustache artwork at every macOS size. `CFBundleIconName` explicitly names the compiled asset. `Scripts/RenderAppIcon.swift` regenerates both the iconset and asset catalog before release builds. `Scripts/verify-app-resources.py` checks the built bundle’s icon metadata, compiled asset renditions, and fallback icon before preview signing and release packaging. Notification Center icon appearance and activation during a signed upgrade still require a native smoke test.

### Compact Settings window

Settings is organized into Camera, Overlay, and App tabs. Camera and Overlay retain a preview that fits the available width and height; App groups extension recovery, login, updates, and version information in a scrolling form. The attention banner remains visible across all tabs. Only the Camera and Overlay tabs count as preview demand. The App tab has no preview and never creates physical camera demand. AppKit occlusion and window lifecycle events release unused preview capture while preserving independent video consumer demand.

The preferred content size is 1100×720, with a usual minimum of 860×560. The underlying content can fit smaller displays; AppKit clamps the saved frame and minimum size to the screen’s visible area, leaving room for system UI. Window resize, display changes, and monitor disconnection recheck those bounds. WindowLayoutTests covers oversized saved frames, laptop scaling, disconnected monitors, negative display coordinates, and already-fitting windows.

### Stale process discovery after activation

The signed 1.0.6→1.0.7 upgrade on macOS 27 exposed a second failure after registration recovered: the extension process was running and a fresh CMIO client could read its source, but the already-running host never received the new provider in its device list. Resetting the sink and resubmitting activation did not refresh that process-local discovery state. A normal host relaunch restored real frames and readable QR output.

After the existing bounded retries, an activation completed in this process may run the same executable in `--probe-virtual-camera` mode. This entry point runs before SwiftUI/AppModel initialization, reads device metadata only, and exits; it never starts streams, physical capture, notifications, updates, or activation. The parent allows five seconds, terminates only its own probe on timeout, and returns to the visible recovery actions if it fails.

Only when that fresh process sees the virtual camera while the host cannot see it does the app relaunch itself once. A per-bundled-version marker persists across launches and healthy connections to prevent loops. Ordinary sink failures and cameras unavailable to the probe do not trigger this fallback. Relaunch preserves unsaved overlay edits separately from applied preferences, the selected Settings tab, window visibility, and foreground/background behavior. Normal termination closes capture before the helper reopens the app; no macOS camera services are restarted. A ten-second watchdog prevents indefinite progress if termination fails.

Structured diagnostics include initial/changed device counts, device-list query failures and recovery, the fresh probe result/exit/timeout, and the guarded restart decision. They contain no frames or overlay values. Controlled installer tests cover the persisted limit, absent devices, stale probe callbacks, and termination that never finishes; LaunchBehavior and recovery-draft tests cover hidden/background launch and unsaved edits.

### Independent camera releases and registration repair

App and camera extension versions are independent. `Config/CameraExtension-Version.xcconfig` pins the unchanged driver to 1.0.9 (21), so app-only updates verify the existing camera without replacing it. The release record in `Config/CameraExtensionRelease.json` fingerprints the extension's actual Xcode source inputs, Info.plist, and entitlements. `Scripts/verify-extension-version.py` verifies the source record, independent target settings, built bundle, and version transition against the previous commit. A driver code change requires a new driver version; an app-only version bump must retain it. Preview, release, and DMG builds check this policy.

Native testing reproduced macOS removing the old CMIO launch job asynchronously and submitting its replacement five milliseconds later, receiving EALREADY. Repeating activation returned success without creating the missing provider. The app now distinguishes an available camera, a confirmed absent provider, and an inconclusive probe. Only confirmed absence offers **Repair Virtual Camera**; a timeout or failed query never justifies registration removal. An absent provider cannot be repaired by restarting the host app.

Repair is a deliberate user action. It pauses capture, requests deactivation, waits for its completion and a two-second settling period, then submits fresh activation. macOS requires renewed approval, which is exposed through the existing warning icon, notification, and Settings action. A reboot-required result and failed removal stop the sequence. Quitting cancels scheduled reactivation and late callbacks. After approval, the normal bounded connection check and stale-process fallback resume. The controlled native repair using the unchanged notarized extension restored 179 source frames and 17 successful QR decodes without restarting camera services.

The external Sparkle test driver must have the production helper's signing team. Otherwise upstream Sparkle deliberately selects a different replacement path. The dependency test patch and reproduction commands are in `Tests/Dependencies/README.md`. A driver identity check is mandatory before the real signed upgrade smoke test.

### Zoom device-list refresh

Zoom kept its old camera list after the provider was repaired: its process predated registration, while a fresh AVFoundation client discovered MovemberCam. A normal Zoom restart connected to the provider, and the user confirmed MovemberCam was selectable and its preview worked. A successful low-level stream test alone is insufficient evidence for this client behavior.

`ZoomRestartTracker` persists the camera availability epoch and the specific Zoom PID plus launch date. It records registration, repair, and approval transitions, reconciles client identity on workspace events and background checks, and seeds first-run tracking from the matching provider's process start time. Only the matching provider time is retained from process metadata; other process data and meeting content are neither stored nor logged. The warning clears after Zoom quits/reopens or the user confirms the camera is already listed, and acknowledgement applies only to that camera epoch.

The restart-needed issue participates in the existing icon badge and notification policy even when the backend is healthy and Settings is closed. It has explicit restart actions in the menu, Settings banner, and notification. Restart is user initiated, uses normal termination, rechecks process identity, waits up to 30 seconds, and never force-quits Zoom. Failure remains actionable. Core permission/capture failures take priority. Tests cover stale process identities, restart persistence, approval timing, acknowledgement, denied quit, notification delivery/limits, and stale notification actions. A native disposable-client test exercises the production relaunch implementation without interrupting Zoom.

The opt-in native Settings check, `bash Scripts/check-preview-lifecycle.sh`, drives the production MainWindow and AppDelegate through tab changes, minimize/restore, full window coverage, and close events with an inert camera. It briefly displays test windows and does not request camera or notification access. Preview-demand logs record the tab and window visibility reasons whenever eligibility changes.
