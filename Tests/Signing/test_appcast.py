import base64
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("appcast", ROOT / "Scripts/appcast.py")
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.feed = pathlib.Path(self.directory.name) / "appcast.xml"
        self.feed.write_text('<rss version="2.0"><channel><title>MovemberCam</title></channel></rss>')
        self.signature = base64.b64encode(bytes(range(64))).decode()

    def add(self, build="6", version="1.0.1"):
        appcast.add_release(self.feed, version, build,
            f"https://github.com/grahamgilbert/movembercam/releases/download/v{version}/MovemberCam-{version}.dmg",
            f'sparkle:edSignature="{self.signature}" length="12345"')

    def test_feed_keeps_marketing_version_and_monotonic_build_separate(self):
        self.add()
        item = ET.parse(self.feed).find("channel/item")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}version"), "6")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}shortVersionString"), "1.0.1")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}minimumSystemVersion"), "14.0")
        self.assertEqual(item.find("enclosure").get(f"{{{appcast.SPARKLE}}}edSignature"), self.signature)

    def test_retry_does_not_duplicate_the_release_and_older_builds_are_rejected(self):
        self.add()
        self.add()
        self.assertEqual(len(ET.parse(self.feed).findall("channel/item")), 1)
        with self.assertRaises(ValueError):
            self.add(build="5", version="1.0.2")

    def test_promotion_preserves_the_original_archive_signature(self):
        self.add()
        stable = pathlib.Path(self.directory.name) / "stable.xml"
        stable.write_text('<rss version="2.0"><channel><title>Stable</title></channel></rss>')
        appcast.promote(self.feed, stable, "1.0.1")
        appcast.promote(self.feed, stable, "1.0.1")
        items = ET.parse(stable).findall("channel/item")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].find("enclosure").get(f"{{{appcast.SPARKLE}}}edSignature"), self.signature)
        with self.assertRaises(ValueError):
            appcast.promote(self.feed, stable, "9.9.9")

    def test_invalid_signatures_are_rejected(self):
        for signature in ['sparkle:edSignature="invalid!" length="10"',
                          f'sparkle:edSignature="{self.signature}" length="0"']:
            with self.assertRaises(ValueError):
                appcast.signature_attributes(signature)

    def test_release_notes_escape_markup(self):
        result = appcast.release_notes('## Changes\n- <script>alert(1)</script>', "1.0.1")
        self.assertNotIn("<script>", result)
        self.assertIn("&lt;script&gt;", result)

    def test_app_requires_signed_feeds_and_checks_hourly(self):
        with (ROOT / "Config/App-Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["SUScheduledCheckInterval"], 3600)
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"])), 32)
