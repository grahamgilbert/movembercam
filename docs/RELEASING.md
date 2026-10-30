# CI and releases

Every push to `main` and every pull request runs the XCTest unit suite, the real video/QR integration checks, and a macOS app plus camera-extension build. These checks need no Apple credentials or camera hardware. Test results and the synthetic overlay render are saved as workflow artifacts.

The Release workflow runs the same checks on the selected commit before it imports signing credentials. It builds a universal Developer ID-signed app, creates the drag-to-Applications DMG, submits the DMG to Apple for notarization, staples and validates the ticket, and creates a GitHub release with the DMG and SHA-256 checksum. Release signing runs only for an explicit manual release, never on pull requests.

## One-time GitHub configuration

In **Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing your **Developer ID Application** certificate and its private key. Export this identity from Keychain Access. An Apple Development certificate is not sufficient. |
| `P12_PASSWORD` | The password used to protect the exported `.p12`. |
| `BUILD_PROVISION_PROFILE_BASE64` | Base64-encoded **Developer ID** provisioning profile for `com.grahamgilbert.MovemberCam`, with the System Extension capability and the certificate in the `.p12`. An existing Xcode-generated Developer ID profile is supported. |
| `APPLE_ID` | The Apple Account email for the developer team. |
| `APPLE_ID_PASSWORD` | An app-specific password created for notarization at [Apple Account](https://account.apple.com/). Use an app-specific password, not your normal account password. |

The signing/notarization secret names match Limpet. Supply your ten-character personal developer team ID as the `APPLE_TEAM_ID` secret or repository variable. The initial repository setup sets this to `9D8XP85393`.

To encode a file on macOS, run `base64 -i /path/to/file` and paste the result into the corresponding GitHub secret. Do not commit the `.p12`, private key, provisioning profile, password, or local `Config/Signing.xcconfig`.

The profile can come from `MovemberCam.app/Contents/embedded.provisionprofile` in an existing Developer ID-exported app, or from the Apple Developer portal. The camera extension uses the same team and signing certificate; its sandbox/App Group entitlements do not require a separate profile in this project.

On the runner, credentials live in a temporary keychain and temporary files. Cleanup runs even if the release fails. `Scripts/ci-setup-signing.sh` validates the profile's team, app identifier, System Extension entitlement, and expiry. Like Limpet, CI builds first and then explicitly signs the bundle: `Scripts/sign-release-app.sh` embeds the profile, selects its matching Developer ID identity, expands the production entitlements, signs the camera extension first, and signs the host app with hardened runtime and Apple timestamps. This supports existing Xcode-managed profiles without requiring Xcode account login or manual provisioning during compilation.

## Publish a version

1. Update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `project.yml`. The app and extension share both values.
2. Regenerate the checked-in Xcode project with `xcodegen generate`, commit the change, and push `main`.
3. Open **Actions → Release (Manual) → Run workflow** on `main`, just as for Limpet. The workflow reads `MARKETING_VERSION` from `project.yml`; no pre-created git tag is needed.

The successful workflow creates the matching `vMAJOR.MINOR.PATCH` tag at the selected commit and publishes the GitHub release. After adding or correcting secrets, rerun the workflow from Actions.

The workflow creates the release only after tests, signing, notarization, and payload verification succeed. It does not replace an existing published release.

## Run checks locally

```sh
swift test
python3 -m unittest discover -s Tests/Signing -v
bash Scripts/verify.sh
bash Scripts/build.sh preview
```

The unit tests cover link validation and boundaries, independent written and QR URLs, persistence and migration, setup readiness, certificate/profile matching, and the camera extension's required Mach service/App Group relationship after an unsigned build. The integration checks render synthetic camera frames and use Vision to read the QR code and text, verify mirroring and overlay bypass, and check QR readability after downscaling.

For local distribution builds, use `bash Scripts/build-dmg.sh --notarize PROFILE` with an existing `notarytool` profile, or `--notarize-xcode` with the developer account signed into Xcode. The first mode notarizes and staples the DMG itself; the Xcode mode packages an app that already has its notarization ticket stapled.
