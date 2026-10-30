import copy
import datetime
import hashlib
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_signing", ROOT / "Scripts/release_signing.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = pathlib.Path(self.directory.name) / "MovemberCam.app"
        self.output = pathlib.Path(self.directory.name) / "entitlements"
        self.info = self.app / "Contents/Info.plist"
        self.extension_info = self.app / "Contents/Library/SystemExtensions" / signing.EXTENSION_NAME / "Contents/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.extension_info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.grahamgilbert.MovemberCam"}))
        self.extension_info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.grahamgilbert.MovemberCam.CameraExtension", "CFBundleVersion": "5",
            "CMIOExtension": {"CMIOExtensionMachServiceName": "com.grahamgilbert.MovemberCam.CameraExtension"}
        }))
        self.team = "ABCDEFGHIJ"
        self.now = datetime.datetime(2026, 10, 30)
        certificate = b"unit test public certificate data"
        self.fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        self.identities = f'1) {self.fingerprint} "Developer ID Application: Test ({self.team})"'
        self.profile = {"TeamIdentifier": [self.team], "DeveloperCertificates": [certificate],
                        "ExpirationDate": self.now + datetime.timedelta(days=30),
                        "Entitlements": {"com.apple.application-identifier": self.team + ".com.grahamgilbert.MovemberCam",
                                         "com.apple.developer.system-extension.install": True}}

    def prepare(self, profile=None, identities=None):
        return signing.prepare_release(self.app, self.team, profile or self.profile,
            self.identities if identities is None else identities, ROOT / "Config", self.output, self.now)

    def test_unsigned_extension_gets_matching_service_and_sandbox_group(self):
        self.assertEqual(self.prepare(), self.fingerprint)
        host = plistlib.loads((self.output / "App.entitlements").read_bytes())
        extension = plistlib.loads((self.output / "Extension.entitlements").read_bytes())
        info = plistlib.loads(self.extension_info.read_bytes())
        service = self.team + ".com.grahamgilbert.MovemberCam.CameraExtension"
        self.assertEqual(info["CMIOExtension"]["CMIOExtensionMachServiceName"], service)
        self.assertIn(service, extension["com.apple.security.application-groups"])
        self.assertTrue(extension["com.apple.security.app-sandbox"])
        self.assertEqual(info["CFBundleVersion"], "5")
        self.assertEqual(host["com.apple.application-identifier"], self.team + ".com.grahamgilbert.MovemberCam")
        self.assertEqual(host["com.apple.developer.team-identifier"], self.team)
        self.assertTrue(host["com.apple.security.device.camera"])
        self.assertTrue(host["com.apple.developer.system-extension.install"])

    def test_invalid_profiles_do_not_modify_the_app(self):
        invalid = []
        for key, value in [("TeamIdentifier", ["WRONGTEAM1"]), ("ExpirationDate", self.now)]:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            invalid.append(profile)
        for key, value in [("com.apple.application-identifier", self.team + ".another.app"),
                           ("com.apple.developer.system-extension.install", False),
                           ("get-task-allow", True), ("com.apple.security.get-task-allow", True)]:
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"][key] = value
            invalid.append(profile)
        original = self.extension_info.read_bytes()
        for profile in invalid:
            with self.subTest(profile=profile):
                with self.assertRaises(ValueError):
                    self.prepare(profile=profile)
                self.assertEqual(self.extension_info.read_bytes(), original)
                self.assertFalse(self.output.exists())

    def test_certificate_must_be_allowed_by_profile_and_belong_to_team(self):
        for identities in ["", self.identities.replace(self.fingerprint, "0" * 40),
                           self.identities.replace(self.team, "WRONGTEAM1"),
                           self.identities.replace("Developer ID Application:", "Apple Development:")]:
            with self.subTest(identities=identities):
                with self.assertRaises(ValueError):
                    self.prepare(identities=identities)
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
