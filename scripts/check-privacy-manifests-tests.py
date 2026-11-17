#!/usr/bin/env python3
"""Pure mapping and manifest regressions for check-privacy-manifests.py."""

import runpy
from pathlib import Path
import plistlib
import unittest


CHECKER = runpy.run_path(str(Path(__file__).with_name("check-privacy-manifests.py")))


class PrivacyManifestTests(unittest.TestCase):
    def test_user_defaults_symbols_and_selectors(self):
        output = """
        (undefined) external _OBJC_CLASS_$_NSUserDefaults
        standardUserDefaults
        initWithSuiteName:
        """
        self.assertIn("NSPrivacyAccessedAPICategoryUserDefaults", CHECKER["detected_categories"](output))

    def test_file_timestamp_symbols_and_selectors(self):
        output = """
        external _NSURLContentModificationDateKey
        _NSFileModificationDate
        -[NSFileManager setAttributes:ofItemAtPath:error:]
        URLResourceValues.contentModificationDate
        (undefined) external _stat
        """
        self.assertIn("NSPrivacyAccessedAPICategoryFileTimestamp", CHECKER["detected_categories"](output))

    def test_disk_space_symbols_and_selectors(self):
        output = "volumeAvailableCapacityForImportantUsage _statfs"
        self.assertIn("NSPrivacyAccessedAPICategoryDiskSpace", CHECKER["detected_categories"](output))

    def test_boot_time_and_active_keyboard_categories(self):
        output = "systemUptime mach_absolute_time activeInputModes primaryLanguage"
        categories = CHECKER["detected_categories"](output)
        self.assertIn("NSPrivacyAccessedAPICategorySystemBootTime", categories)
        self.assertIn("NSPrivacyAccessedAPICategoryActiveKeyboards", categories)

    def test_unrelated_symbols_do_not_trigger_categories(self):
        self.assertEqual(set(), CHECKER["detected_categories"]("static clock_gettime continuousClock"))

    def test_manifest_categories_and_missing_category_mapping(self):
        manifest = {
            "NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults"},
                {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp"},
            ]
        }
        declared = CHECKER["manifest_categories"](manifest)
        detected = CHECKER["detected_categories"]("_OBJC_CLASS_$_NSUserDefaults _statfs")
        missing = CHECKER["missing_categories"](detected, declared)
        self.assertEqual({"NSPrivacyAccessedAPICategoryDiskSpace"}, missing)

    def test_empty_manifest_fails_for_detected_widget_symbols(self):
        detected = CHECKER["detected_categories"](
            "_OBJC_CLASS_$_NSUserDefaults standardUserDefaults "
            "_NSURLContentModificationDateKey URLResourceValues.contentModificationDate"
        )
        self.assertEqual(
            {
                "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPICategoryFileTimestamp",
            },
            CHECKER["missing_categories"](detected, CHECKER["manifest_categories"]({})),
        )

    def test_widget_manifest_declares_reasons_for_linked_package_apis(self):
        manifest_path = Path(__file__).resolve().parent.parent / "AudiobookshelfWidgets/PrivacyInfo.xcprivacy"
        with manifest_path.open("rb") as stream:
            manifest = plistlib.load(stream)
        declarations = {
            entry["NSPrivacyAccessedAPIType"]: set(entry["NSPrivacyAccessedAPITypeReasons"])
            for entry in manifest["NSPrivacyAccessedAPITypes"]
        }
        self.assertEqual(
            {
                "CA92.1",
                "1C8F.1",
            },
            declarations["NSPrivacyAccessedAPICategoryUserDefaults"],
        )
        self.assertEqual(
            {"C617.1"},
            declarations["NSPrivacyAccessedAPICategoryFileTimestamp"],
        )
        self.assertNotIn("NSPrivacyAccessedAPICategoryDiskSpace", declarations)

    def test_malformed_accessed_api_list_fails_closed(self):
        with self.assertRaises(ValueError):
            CHECKER["manifest_categories"]({"NSPrivacyAccessedAPITypes": {}})
        with self.assertRaises(ValueError):
            CHECKER["manifest_categories"]([])


if __name__ == "__main__":
    unittest.main(verbosity=2)
