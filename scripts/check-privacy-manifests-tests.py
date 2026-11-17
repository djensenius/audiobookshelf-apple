#!/usr/bin/env python3
"""Pure mapping and manifest regressions for check-privacy-manifests.py."""

import runpy
from pathlib import Path
import plistlib
from types import SimpleNamespace
import unittest


CHECKER = runpy.run_path(str(Path(__file__).with_name("check-privacy-manifests.py")))


class PrivacyManifestTests(unittest.TestCase):
    def assert_category_for_each(self, category, forms):
        for form in forms:
            with self.subTest(form=form):
                self.assertEqual({category}, CHECKER["detected_categories"](form))

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

    def test_raw_swift_mangled_symbols_are_demangled_before_detection(self):
        examples = [
            (
                "_$s10Foundation17URLResourceValuesV19volumeTotalCapacitySiSgvg",
                "Foundation.URLResourceValues.volumeTotalCapacity.getter : Swift.Int?",
                "NSPrivacyAccessedAPICategoryDiskSpace",
            ),
            (
                "_$s10Foundation17URLResourceValuesV12creationDate10Foundation4DateVSgvg",
                "Foundation.URLResourceValues.creationDate.getter : Foundation.Date?",
                "NSPrivacyAccessedAPICategoryFileTimestamp",
            ),
            (
                "_$s10Foundation17URLResourceValuesV20fileModificationDate10Foundation4DateVSgvg",
                "Foundation.URLResourceValues.fileModificationDate.getter : Foundation.Date?",
                "NSPrivacyAccessedAPICategoryFileTimestamp",
            ),
        ]
        for mangled, demangled, category in examples:
            with self.subTest(mangled=mangled):
                self.assertEqual(set(), CHECKER["detected_categories"](mangled))

                def fake_run(command, **kwargs):
                    self.assertEqual(["xcrun", "swift-demangle"], command)
                    return SimpleNamespace(returncode=0, stdout=demangled, stderr="")

                self.assertEqual({category}, CHECKER["detected_binary_categories"](mangled, run=fake_run))

    def test_swift_demangler_falls_back_to_path_executable(self):
        commands = []

        def fake_run(command, **kwargs):
            commands.append(command)
            if command[0] == "xcrun":
                raise FileNotFoundError("xcrun unavailable")
            return SimpleNamespace(returncode=0, stdout="demangled", stderr="")

        self.assertEqual("demangled", CHECKER["demangle_output"]("mangled", run=fake_run))
        self.assertEqual([["xcrun", "swift-demangle"], ["swift-demangle"]], commands)

    def test_missing_swift_demangler_fails_clearly(self):
        def unavailable(command, **kwargs):
            raise FileNotFoundError(f"{command[0]} unavailable")

        with self.assertRaisesRegex(ValueError, "Swift demangler unavailable or failed"):
            CHECKER["demangle_output"]("mangled", run=unavailable)

    def test_file_timestamp_creation_and_modification_date_forms_individually(self):
        self.assert_category_for_each(
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            [
                "NSURLCreationDateKey",
                "_NSURLCreationDateKey",
                "NSFileCreationDate",
                "URLResourceValues.creationDate",
                "FileAttributeKey.creationDate",
                "fileCreationDate",
                "creationDateKey",
                "NSURLContentModificationDateKey",
                "NSFileModificationDate",
                "URLResourceValues.fileModificationDate",
                "FileAttributeKey.modificationDate",
                "fileModificationDate",
                "fileModificationDateKey",
                "modificationDate",
                "contentModificationDateKey",
                "-[NSFileManager attributesOfItemAtPath:error:]",
                "-[NSFileManager setAttributes:ofItemAtPath:error:]",
                "_utime",
                "_futimesat",
            ],
        )

    def test_disk_space_symbols_and_selectors(self):
        output = "volumeAvailableCapacityForImportantUsage _statfs"
        self.assertIn("NSPrivacyAccessedAPICategoryDiskSpace", CHECKER["detected_categories"](output))

    def test_disk_space_constants_and_selectors_individually(self):
        self.assert_category_for_each(
            "NSPrivacyAccessedAPICategoryDiskSpace",
            [
                "NSURLVolumeTotalCapacityKey",
                "_NSURLVolumeTotalCapacityKey",
                "volumeTotalCapacity",
                "NSURLVolumeAvailableCapacityKey",
                "NSURLVolumeAvailableCapacityForImportantUsageKey",
                "NSURLVolumeAvailableCapacityForOpportunisticUsageKey",
                "volumeAvailableCapacity",
                "volumeAvailableCapacityForImportantUsage",
                "volumeAvailableCapacityForOpportunisticUsage",
                "NSFileSystemFreeSize",
                "NSFileSystemSize",
                "FileAttributeKey.systemFreeSize",
                "FileAttributeKey.systemSize",
                "attributesOfFileSystemForPath:error:",
                "_statfs",
                "_fstatfs",
                "_statvfs",
                "_fstatvfs",
                "_getfsstat",
                "_getmntinfo",
            ],
        )
        self.assertEqual(
            set(),
            CHECKER["detected_categories"](
                "subsystemSize systemSizeHelper mysystemSize systemSizeSuffix "
                "volumeTotalCapacityCache NSFileSystemSizeValue"
            ),
        )

    def test_boot_time_apis_individually(self):
        self.assert_category_for_each(
            "NSPrivacyAccessedAPICategorySystemBootTime",
            [
                "ProcessInfo.systemUptime",
                "_mach_absolute_time",
                "_mach_continuous_time",
                "_mach_approximate_time",
                "_mach_continuous_approximate_time",
                "CACurrentMediaTime",
            ],
        )

    def test_active_keyboard_apis_individually(self):
        self.assert_category_for_each(
            "NSPrivacyAccessedAPICategoryActiveKeyboards",
            [
                "activeInputModes",
                "UITextInputMode.primaryLanguage",
            ],
        )

    def test_unrelated_symbols_do_not_trigger_categories(self):
        self.assertEqual(set(), CHECKER["detected_categories"]("static clock_gettime continuousClock"))

    def test_manifest_categories_and_missing_category_mapping(self):
        manifest = {
            "NSPrivacyAccessedAPITypes": [
                {
                    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                    "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                },
                {
                    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                    "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
                },
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

    def test_missing_or_empty_reasons_fail_closed(self):
        category = "NSPrivacyAccessedAPICategoryUserDefaults"
        with self.assertRaisesRegex(ValueError, "non-empty reason strings"):
            CHECKER["manifest_categories"](
                {"NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": category}]}
            )
        with self.assertRaisesRegex(ValueError, "non-empty reason strings"):
            CHECKER["manifest_categories"](
                {
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": category,
                            "NSPrivacyAccessedAPITypeReasons": [],
                        }
                    ]
                }
            )
        with self.assertRaisesRegex(ValueError, "non-empty reason strings"):
            CHECKER["manifest_categories"](
                {
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": category,
                            "NSPrivacyAccessedAPITypeReasons": ["  "],
                        }
                    ]
                }
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
