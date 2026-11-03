#!/usr/bin/env python3
"""Keep an unchanged camera driver installed across app-only updates."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = "Config/CameraExtensionRelease.json"


def source_inputs(root):
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(root / "MovemberCam.xcodeproj/project.pbxproj")]))
    objects = project["objects"]
    parents = {child: key for key, obj in objects.items() for child in obj.get("children", [])}

    def path(key):
        obj = objects[key]
        name = pathlib.Path(obj.get("path", ""))
        return path(parents[key]) / name if obj.get("sourceTree") == "<group>" and key in parents else name

    target = next(obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "CameraExtension")
    sources = [str(path(objects[item]["fileRef"]))
               for phase in target["buildPhases"] if objects[phase]["isa"] == "PBXSourcesBuildPhase"
               for item in objects[phase]["files"]]
    return sorted(sources + ["Config/Extension-Info.plist", "Config/Extension.entitlements"])


def fingerprint(root, inputs):
    result = hashlib.sha256()
    for name in inputs:
        data = (root / name).read_bytes()
        result.update(name.encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return result.hexdigest()


def verify_transition(previous, current):
    same_version = (previous["release"], previous["build"]) == (current["release"], current["build"])
    same_code = previous["source_sha256"] == current["source_sha256"]
    if same_version and not same_code:
        raise ValueError("Camera extension inputs changed: increment its independent version before updating the release record.")
    if not same_version and same_code:
        raise ValueError("Camera extension inputs are unchanged: retain its existing version for app-only updates.")
    if not same_version:
        def version(value):
            return tuple(int(part) for part in value["release"].split(".")), int(value["build"])
        if version(current) <= version(previous):
            raise ValueError("Camera extension versions must increase when its inputs change.")


def verify(root, app=None):
    record = json.loads((root / LOCK).read_text())
    inputs = source_inputs(root)
    if inputs != record["inputs"] or fingerprint(root, inputs) != record["source_sha256"]:
        raise ValueError("Camera extension inputs differ from its release record. Version and record the driver change explicitly.")
    settings = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)",
                              (root / "Config/CameraExtension-Version.xcconfig").read_text(), re.M))
    if (settings.get("MARKETING_VERSION"), settings.get("CURRENT_PROJECT_VERSION")) != (record["release"], record["build"]):
        raise ValueError("Camera extension configuration and release record versions differ.")
    previous = subprocess.run(["git", "show", "HEAD^:" + LOCK], cwd=root, capture_output=True, text=True)
    if previous.returncode == 0:
        verify_transition(json.loads(previous.stdout), record)
    if app:
        info = pathlib.Path(app) / "Contents/Library/SystemExtensions/com.grahamgilbert.MovemberCam.CameraExtension.systemextension/Contents/Info.plist"
        with info.open("rb") as stream:
            bundle = plistlib.load(stream)
        if (bundle["CFBundleShortVersionString"], bundle["CFBundleVersion"]) != (record["release"], record["build"]):
            raise ValueError("Built camera extension inherited the app version instead of its independent version.")
    print(f"Camera extension {record['release']} ({record['build']}): source inputs and independent version verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    try:
        verify(ROOT, args.app)
    except (ValueError, OSError, KeyError, StopIteration) as error:
        parser.exit(1, str(error) + "\n")
