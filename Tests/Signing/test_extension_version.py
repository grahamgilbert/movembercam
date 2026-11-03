import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("extension_version", pathlib.Path(__file__).resolve().parents[2] / "Scripts/verify-extension-version.py")
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


class ExtensionVersionTests(unittest.TestCase):
    def setUp(self):
        self.previous = {"release": "1.0.9", "build": "21", "source_sha256": "unchanged"}

    def test_app_only_update_reuses_driver(self):
        versioning.verify_transition(self.previous, dict(self.previous))

    def test_changed_driver_requires_version_bump(self):
        with self.assertRaisesRegex(ValueError, "increment"):
            versioning.verify_transition(self.previous, dict(self.previous, source_sha256="changed"))

    def test_host_version_bump_must_not_replace_unchanged_driver(self):
        with self.assertRaisesRegex(ValueError, "unchanged"):
            versioning.verify_transition(self.previous, dict(self.previous, release="1.0.10", build="22"))

    def test_changed_driver_with_new_version_is_valid(self):
        versioning.verify_transition(self.previous, {"release": "1.0.10", "build": "22", "source_sha256": "changed"})

    def test_driver_downgrades_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "increase"):
            versioning.verify_transition(self.previous, {"release": "1.0.8", "build": "20", "source_sha256": "changed"})
