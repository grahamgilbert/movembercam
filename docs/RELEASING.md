# CI and releases

Every push to `main` and every pull request runs the XCTest unit suite, the real video/QR integration checks, and a macOS app plus camera-extension build. These checks need no Apple credentials or camera hardware. Test results and the synthetic overlay render are saved as workflow artifacts.

The Release workflow runs the same checks on the selected commit before it imports signing credentials. It builds a universal Developer ID-signed app, creates the drag-to-Applications DMG, submits the DMG to Apple for notarization, staples and validates the ticket, and creates a GitHub release with the DMG and SHA-256 checksum. Release signing runs only for an explicit manual release, never on pull requests.

## One-time GitHub configuration

In **Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing your **Developer ID Application** certificate and its private key. Export this identity from Keychain Access. An Apple Development certificate is not sufficient. |
| `P12_PASSWORD` | The password used to protect the exported `.p12`. |
| `BUILD_PROVISION_PROFILE_BASE64` | Base64-encoded, **manually managed Developer ID** provisioning profile for `com.grahamgilbert.MovemberCam`, with the System Extension capability. Create/download it in the Apple Developer portal and select the same certificate as the `.p12`. |
| `APPLE_ID` | The Apple Account email for the developer team. |
| `APPLE_ID_PASSWORD` | An app-specific password created for notarization at [Apple Account](https://account.apple.com/). Use an app-specific password, not your normal account password. |

The signing/notarization secret names match Limpet. Supply your ten-character personal developer team ID as the `APPLE_TEAM_ID` secret or repository variable. The initial repository setup sets this to `9D8XP85393`.

To encode a file on macOS, run `base64 -i /path/to/file` and paste the result into the corresponding GitHub secret. Do not commit the `.p12`, private key, provisioning profile, password, or local `Config/Signing.xcconfig`.

The local Xcode-generated profile named `Mac Team Direct Provisioning Profile: …` cannot be used for CI manual signing. Create a Developer ID profile manually under **Certificates, Identifiers & Profiles → Profiles**, selecting the MovemberCam app identifier and your Developer ID Application certificate. The camera extension uses the same team and signing certificate; its sandbox/App Group entitlements do not require a separate profile in this project.

On the runner, credentials live in a temporary keychain and temporary files. Cleanup runs even if the release fails. `Scripts/ci-setup-signing.sh` validates the profile's team, app identifier, System Extension entitlement, and expiry, then configures manual signing. This avoids depending on a developer account being logged into Xcode on the runner.

## Publish a version

1. Update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `project.yml`. The app and extension share both values.
2. Regenerate the checked-in Xcode project with `xcodegen generate`, commit the change, and push `main`.
3. Open **Actions → Release (Manual) → Run workflow** on `main`, just as for Limpet. The workflow reads `MARKETING_VERSION` from `project.yml`; no pre-created git tag is needed.

The successful workflow creates the matching `vMAJOR.MINOR.PATCH` tag at the selected commit and publishes the GitHub release. After adding or correcting secrets, rerun the workflow from Actions.

The workflow creates the release only after tests, signing, notarization, and payload verification succeed. It does not replace an existing published release.

## Run checks locally

```sh
swift test
bash Scripts/verify.sh
bash Scripts/build.sh preview
```

The unit tests cover link validation and boundaries, independent written and QR URLs, persistence and migration, and setup readiness. The integration checks render synthetic camera frames and use Vision to read the QR code and text, verify mirroring and overlay bypass, and check QR readability after downscaling.

For local distribution builds, use `bash Scripts/build-dmg.sh --notarize PROFILE` with an existing `notarytool` profile, or `--notarize-xcode` with the developer account signed into Xcode. The first mode notarizes and staples the DMG itself; the Xcode mode packages an app that already has its notarization ticket stapled.
