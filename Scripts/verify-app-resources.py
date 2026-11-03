#!/usr/bin/env python3
"""Validate the actual built icon resources used by macOS, before signing."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1])
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
name = info.get("CFBundleIconName")
if name != "AppIcon":
    sys.exit("App icon asset name is missing or incorrect")
resources = app / "Contents/Resources"
fallback = resources / (info.get("CFBundleIconFile", "").removesuffix(".icns") + ".icns")
if not fallback.is_file() or fallback.read_bytes()[:4] != b"icns":
    sys.exit("App icon fallback is missing or invalid")
assets = resources / "Assets.car"
if not assets.is_file():
    sys.exit("Compiled icon asset catalog is missing")
entries = json.loads(subprocess.check_output(["xcrun", "assetutil", "--info", str(assets)]))
sizes = {(entry.get("PixelWidth"), entry.get("PixelHeight")) for entry in entries if entry.get("Name") == name}
required = {(size, size) for size in [16, 32, 64, 128, 256, 512, 1024]}
if not required.issubset(sizes):
    sys.exit("App icon asset is missing required resolutions: " + str(required - sizes))
print("App icon metadata, compiled asset, fallback, and resolutions verified")
