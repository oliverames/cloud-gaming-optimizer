#!/usr/bin/env python3
"""Regression tests using isolated feeds and buyer-content fixtures."""
import copy
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import publish_gumroad as gumroad
import update_appcast as appcast


class AppcastTests(unittest.TestCase):
    def item(self, version, build):
        return ET.fromstring(f'''<item xmlns:sparkle="{appcast.SPARKLE}">
          <sparkle:version>{build}</sparkle:version>
          <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
          <description>Changes</description><enclosure url="https://example.invalid/{version}.dmg" />
        </item>''')

    def test_paid_boundary_and_notice_survive_patch_releases(self):
        item = self.item("4.0.2", "40002")
        appcast.normalize(item)
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}minimumAutoupdateVersion"), "40000")
        once = ET.tostring(item)
        appcast.normalize(item)
        self.assertEqual(ET.tostring(item), once)
        free = self.item("3.1.0", "30100")
        appcast.normalize(free)
        self.assertIsNone(free.find(f"{{{appcast.SPARKLE}}}minimumAutoupdateVersion"))

    def test_remove_coupon_from_github_rendered_notes(self):
        item = self.item("4.0.0", "40000")
        item.find("description").text = 'Donors receive a license via a hidden 100% off code (<code class="notranslate">PRIVATE-CODE</code>).'
        appcast.normalize(item)
        self.assertNotIn("PRIVATE-CODE", item.findtext("description"))

    def test_beta_keeps_prereleases_and_receives_stable_idempotently(self):
        with tempfile.TemporaryDirectory() as directory:
            stable, beta, entry = (Path(directory) / name for name in ("appcast.xml", "appcast-beta.xml", "item.xml"))
            ET.ElementTree(self.item("4.1.0-beta.1", "40100")).write(entry)
            appcast.update(stable, beta, entry, beta_release=True)
            ET.ElementTree(self.item("4.0.2", "40002")).write(entry)
            appcast.update(stable, beta, entry)
            first = (stable.read_bytes(), beta.read_bytes())
            appcast.update(stable, beta, entry)
            self.assertEqual(first, (stable.read_bytes(), beta.read_bytes()))
            versions = [appcast.value(i, "shortVersionString") for i in ET.parse(beta).findall("channel/item")]
            self.assertEqual(versions, ["4.1.0-beta.1", "4.0.2"])
            self.assertEqual(len(ET.parse(stable).findall("channel/item")), 1)

    def test_build_comparison_handles_legacy_and_current_formats(self):
        self.assertGreater(appcast.build_key("40002"), appcast.build_key("40001"))
        self.assertGreater(appcast.build_key("40000"), appcast.build_key("3.1.0"))
        with self.assertRaises(ValueError):
            appcast.build_key("4.0.2-beta")


class GumroadContentTests(unittest.TestCase):
    def test_only_versioned_dmgs_are_replaced_and_license_content_survives(self):
        embed = lambda identifier: {"type": "fileEmbed", "attrs": {"id": identifier}}
        pages = [{"id": "first", "description": {"type": "doc", "content": [embed("old"), {"type": "licenseKey"}, {"type": "paragraph", "content": [{"text": "Activation instructions"}]}]}},
                 {"id": "second", "description": {"type": "doc", "content": [embed("guide"), embed("latest")]}}]
        files = [{"id": "old", "name": "PingWarden-4.0.1.dmg"}, {"id": "latest", "name": "PingWarden-4.0.2.dmg"}, {"id": "guide", "name": "Guide.pdf"}]
        original = copy.deepcopy(pages)
        updated, identifier = gumroad.replace_download(pages, files, "PingWarden-4.0.2.dmg")
        self.assertEqual(pages, original)
        self.assertEqual(identifier, "latest")
        self.assertEqual(updated[0]["description"]["content"][0], embed("latest"))
        self.assertEqual([n["attrs"]["id"] for n in gumroad.nodes(updated) if n.get("type") == "fileEmbed"], ["latest", "guide"])
        self.assertEqual([p["id"] for p in updated], ["first", "second"])
        self.assertEqual(sum(n.get("type") == "licenseKey" for n in gumroad.nodes(updated)), 1)
        self.assertEqual(gumroad.replace_download(updated, files, "PingWarden-4.0.2.dmg")[0], updated)

    def test_missing_license_or_wrong_product_blocks_publication(self):
        with self.assertRaises(ValueError):
            gumroad.validate({"id": gumroad.PRODUCT_ID, "published": True}, [])
        with self.assertRaises(ValueError):
            gumroad.validate({"id": "wrong", "published": True}, [{"type": "licenseKey"}])


if __name__ == "__main__":
    unittest.main()
