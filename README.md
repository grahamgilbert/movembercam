# MovemberCam

MovemberCam adds a fundraising QR code, a link, and the Movember logo to your camera feed. Choose MovemberCam as your camera in Zoom or another app that supports virtual cameras to show them during calls.

[Download the latest release](https://github.com/grahamgilbert/movembercam/releases/latest). Requires macOS 14 or later.

![MovemberCam settings](docs/screenshots/settings-demo.png)

## Install

1. Open the downloaded DMG and drag **MovemberCam** into **Applications**.
2. Open MovemberCam and click **Allow Camera Access…** to grant camera permission.
3. Click **Install Virtual Camera** beneath the preview and approve the extension when macOS prompts you. Follow any instructions to restart MovemberCam or your Mac.
4. Choose your physical camera and enter your fundraising links in **QR destination** and **Written URL**. Click **Apply Changes**, then **Start Camera**.
5. Quit and reopen your video app, then select **MovemberCam** as its camera. Keep MovemberCam running during calls.

Reopen your video app after updating the virtual camera. If approval is still pending, follow the macOS prompt to enable the extension in System Settings.

## Using MovemberCam

The QR code destination and the URL displayed on screen can be different. Both default to [movember.com/t/musta-ch](https://movember.com/t/musta-ch); change them in Settings to use your own fundraising page.

You can place the QR card at the bottom left or right and mirror the camera image while keeping the QR code and text readable. Click **Apply Changes** to save changes to the links, position, and mirroring. Camera selection and the menu bar overlay toggle save immediately.

Use the mustache menu bar icon to open Settings, toggle the overlay, start or stop the camera, or quit. Turning off the overlay leaves the camera running. Closing Settings also leaves the app running; use **Stop Camera** or quit to release the camera.

MovemberCam supports built-in, USB, and Continuity cameras. Auto resolution chooses the camera's highest resolution up to 4K at 30 fps, or its nearest available frame rate. The preview shows the actual capture dimensions. The virtual camera matches common camera resolutions, including 720p, 1080p, 1440p, and 4K; your meeting app can request a different output size. Zoom may mirror the text in your self-view, but other participants receive the readable overlay. Audio uses the microphone selected in your meeting app.

Settings also has **Open at Login**, automatic update preferences, and **Check for Updates…**. Launching the app, including at login, does not start the camera.

To remove the virtual camera, stop capture and choose **Camera → Remove Virtual Camera**.

## Development

See [Building and development](docs/DEVELOPMENT.md) for local preview builds, camera-extension signing, DMG packaging, tests, and architecture. [CI and releases](docs/RELEASING.md) covers GitHub Actions and publishing updates.

## Privacy

Video is processed on your Mac. MovemberCam does not upload video or visit your fundraising links. It checks this GitHub repository for app updates; your meeting app transmits the video during calls.

MovemberCam is an independent project and is not affiliated with Movember or Zoom. See [artwork credits](Resources/ATTRIBUTION.md).
