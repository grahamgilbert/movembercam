"""Prepare production entitlements and CMIO metadata before codesigning an unsigned app."""

import datetime
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys

EXTENSION_NAME = "com.grahamgilbert.MovemberCam.CameraExtension.systemextension"


def prepare_release(app, team, profile, identities, config, output, now=None):
    app, config, output = pathlib.Path(app), pathlib.Path(config), pathlib.Path(output)
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    with (app / "Contents/Info.plist").open("rb") as stream:
        bundle = plistlib.load(stream)["CFBundleIdentifier"]
    entitlements = profile.get("Entitlements", {})
    if profile.get("TeamIdentifier") != [team] or entitlements.get("com.apple.application-identifier") != team + "." + bundle:
        raise ValueError("Provisioning profile does not match the app and developer team.")
    if not entitlements.get("com.apple.developer.system-extension.install"):
        raise ValueError("Provisioning profile must allow system extension installation.")
    if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
        raise ValueError("Use a Developer ID distribution profile, not a development profile.")
    if profile["ExpirationDate"] <= now:
        raise ValueError("Provisioning profile has expired.")
    allowed = {hashlib.sha1(certificate).hexdigest().upper() for certificate in profile["DeveloperCertificates"]}
    identity = next((fingerprint for fingerprint, name in re.findall(r'\d+\) ([A-F0-9]{40}) "([^"]+)"', identities)
                     if fingerprint in allowed and name.startswith("Developer ID Application:") and name.endswith("(" + team + ")")), None)
    if not identity:
        raise ValueError("Import the Developer ID Application certificate and private key selected in this profile.")
    with (config / "App.entitlements").open("rb") as stream:
        host = plistlib.load(stream)
    host["com.apple.application-identifier"] = team + "." + bundle
    host["com.apple.developer.team-identifier"] = team
    extension = plistlib.loads((config / "Extension.entitlements").read_bytes()
                              .replace(b"$(TeamIdentifierPrefix)", (team + ".").encode()))
    extension_info_path = app / "Contents/Library/SystemExtensions" / EXTENSION_NAME / "Contents/Info.plist"
    with extension_info_path.open("rb") as stream:
        extension_info = plistlib.load(stream)
    service = team + "." + extension_info["CFBundleIdentifier"]
    if service not in extension.get("com.apple.security.application-groups", []):
        raise ValueError("Camera Mach service must match an allowed sandbox App Group.")
    # Unsigned Xcode builds may leave TeamIdentifierPrefix empty in this plist.
    extension_info["CMIOExtension"]["CMIOExtensionMachServiceName"] = service
    output.mkdir(parents=True, exist_ok=True)
    (output / "identity").write_text(identity)
    for name, value in [("App.entitlements", host), ("Extension.entitlements", extension)]:
        with (output / name).open("wb") as stream:
            plistlib.dump(value, stream)
    with extension_info_path.open("wb") as stream:
        plistlib.dump(extension_info, stream)
    return identity


if __name__ == "__main__":
    with open(sys.argv[3], "rb") as stream:
        profile = plistlib.load(stream)
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    try:
        prepare_release(sys.argv[1], sys.argv[2], profile, identities, "Config", "build/release-entitlements")
    except ValueError as error:
        sys.exit(str(error))
