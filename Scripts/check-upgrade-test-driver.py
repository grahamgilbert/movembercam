#!/usr/bin/env python3
"""Reject a smoke-test driver that would select Sparkle's different-team fallback path."""
import pathlib
import plistlib
import re
import subprocess
import sys


def team(path):
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", result.stderr, re.M)
    if not match:
        raise ValueError(f"{path}: no distribution Team ID; this changes Sparkle's installation path")
    return match.group(1)


def verify(driver, host):
    driver, host = pathlib.Path(driver), pathlib.Path(host)
    expected = team(host)
    versions = []
    for app in (driver, host):
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        if team(app) != expected:
            raise ValueError("Test driver and host app have different signing teams")
        framework = app / "Contents/Frameworks/Sparkle.framework"
        if team(framework / "Versions/Current/Autoupdate") != expected:
            raise ValueError("Test updater helper selects a different installation path from the production helper")
        with (framework / "Resources/Info.plist").open("rb") as stream:
            versions.append(plistlib.load(stream)["CFBundleShortVersionString"])
    if versions[0] != versions[1]:
        raise ValueError("Test driver and production updater use different Sparkle versions")
    with (host / "Contents/Info.plist").open("rb") as stream:
        if "NSUpdateSecurityPolicy" in plistlib.load(stream):
            raise ValueError("Host uses a custom update security policy; verify that installer path separately")
    print(f"Upgrade driver verified: Sparkle {versions[0]}, matching app/helper signing team {expected}")


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
