#!/usr/bin/env python3
"""Release script regressions: python3 scripts/test-release-tests.py (mise run test:release).

Covers scripts/set-version.sh on a copy of Audiobookshelf.xcodeproj in a scratch git
repository (only MARKETING_VERSION changes, invalid versions change nothing, a second
run is a no-op) and the What to Test notes that ci_scripts/ci_post_xcodebuild.sh writes
from CHANGELOG.md (the topmost section with entries, the commit fallback, the archive
gate and the 4,000-character limit), and the release tag check in
ci_scripts/ci_post_clone.sh (a v<x.y.z> CI_TAG must match every MARKETING_VERSION;
other tags are ignored). Nothing outside the scratch directories is touched.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SET_VERSION = ROOT / "scripts/set-version.sh"
FORMATTER = ROOT / "scripts/xcprojformatter.sh"
POST_XCODEBUILD = ROOT / "ci_scripts/ci_post_xcodebuild.sh"
POST_CLONE = ROOT / "ci_scripts/ci_post_clone.sh"
PROJECT = ROOT / "Audiobookshelf.xcodeproj"
TIMEOUT = 120
MAX_NOTES_BYTES = 4000
BASELINE = "0.0.1"


def run(args, cwd=None, env=None, timeout=TIMEOUT):
    return subprocess.run(
        args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout, check=False
    )


def git(repo, *args):
    result = run(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", *args], cwd=repo
    )
    if result.returncode != 0:
        raise AssertionError(f"git {args}: {result.stderr}")
    return result.stdout


def setUpModule():
    # Build the pinned formatter once, outside the per-test timeouts.
    result = run([str(FORMATTER), str(PROJECT)], timeout=1200)
    if result.returncode != 0:
        raise RuntimeError(f"xcprojformatter failed: {result.stderr}")


class SetVersionTests(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="set-version-tests."))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.project = self.scratch / "Audiobookshelf.xcodeproj"
        (self.project).mkdir()
        shutil.copy2(PROJECT / "project.xcproj", self.project / "project.xcproj")
        self.file = self.project / "project.xcproj"
        # Pin every MARKETING_VERSION to a baseline none of the tests set, so the tests
        # don't depend on (or break after a bump of) the repository's current version.
        text, count = re.subn(
            r'("MARKETING_VERSION(?:\[[^\]]*\])*": )"[^"]*"', rf'\1"{BASELINE}"', self.file.read_text()
        )
        self.assertGreaterEqual(count, 1)
        self.file.write_text(text)
        git(self.scratch, "init", "--quiet")
        git(self.scratch, "add", ".")
        git(self.scratch, "commit", "--quiet", "-m", "baseline")

    def set_version(self, *args):
        return run([str(SET_VERSION), *args, str(self.project)], cwd=self.scratch)

    def assert_unchanged(self):
        self.assertEqual(git(self.scratch, "status", "--porcelain", "--untracked-files=all"), "")

    def assert_only_marketing_version(self, version, expected_count):
        self.assertEqual(
            git(self.scratch, "diff", "--name-only").splitlines(),
            ["Audiobookshelf.xcodeproj/project.xcproj"],
        )
        self.assertEqual(git(self.scratch, "status", "--porcelain", "--untracked-files=all").count("\n"), 1)
        removed, added = [], []
        for line in git(self.scratch, "diff", "-U0").splitlines():
            if line.startswith(("---", "+++")):
                continue
            if line.startswith("-"):
                removed.append(line[1:])
            elif line.startswith("+"):
                added.append(line[1:])
        setting = re.compile(r'\s*"MARKETING_VERSION(\[[^\]]*\])?": "([^"]*)",')
        self.assertEqual(len(removed), expected_count, removed)
        self.assertEqual(len(added), expected_count, added)
        for before, after in zip(removed, added):
            self.assertRegex(before, setting)
            self.assertEqual(after, re.sub(r'"[^"]*",$', f'"{version}",', before))
        # The result is canonical, as mise run xcproj:check requires.
        canonical = run([str(FORMATTER), str(self.project)])
        self.assertEqual(canonical.returncode, 0, canonical.stderr)
        self.assertEqual(canonical.stdout, self.file.read_text())

    def test_a_valid_version_changes_only_marketing_version_in_every_target(self):
        count = self.file.read_text().count('"MARKETING_VERSION":')
        self.assertGreaterEqual(count, 3, "app, tests and widgets carry MARKETING_VERSION")
        result = self.set_version("12.3.40")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Set MARKETING_VERSION to 12.3.40", result.stdout)
        self.assert_only_marketing_version("12.3.40", count)
        self.assertNotIn(f'"MARKETING_VERSION": "{BASELINE}"', self.file.read_text())
        self.assertEqual(self.file.stat().st_mode & 0o777, (PROJECT / "project.xcproj").stat().st_mode & 0o777)

    def test_the_project_is_replaced_atomically_and_keeps_its_mode(self):
        self.file.chmod(0o640)  # git ignores this, so the fixture stays committed
        before = self.file.stat().st_ino
        result = self.set_version("3.4.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        # A rename swaps in a new inode; writing through the original would keep it (and
        # could truncate the project if the write failed partway).
        self.assertNotEqual(self.file.stat().st_ino, before)
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o640)
        self.assertEqual(sorted(p.name for p in self.project.iterdir()), ["project.xcproj"])

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_a_failed_staging_write_leaves_the_project_untouched(self):
        original = self.file.read_bytes()
        self.project.chmod(0o555)
        self.addCleanup(self.project.chmod, 0o755)
        result = self.set_version("3.4.5")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.file.read_bytes(), original)
        self.assertEqual(sorted(p.name for p in self.project.iterdir()), ["project.xcproj"])

    def test_conditional_settings_are_set_too(self):
        text = self.file.read_text()
        anchor = '    "MACOSX_DEPLOYMENT_TARGET": "27.0",\n'
        self.assertIn(anchor, text)
        self.file.write_text(text.replace(anchor, anchor + '    "MARKETING_VERSION[config=Debug]": "0.0.9",\n'))
        git(self.scratch, "commit", "--quiet", "-am", "conditional setting")
        count = self.file.read_text().count('"MARKETING_VERSION')
        result = self.set_version("2.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_only_marketing_version("2.0.0", count)
        self.assertIn('"MARKETING_VERSION[config=Debug]": "2.0.0",', self.file.read_text())

    def test_a_second_run_with_the_same_version_changes_nothing(self):
        first = self.set_version("1.0.0")
        self.assertEqual(first.returncode, 0, first.stderr)
        git(self.scratch, "commit", "--quiet", "-am", "1.0.0")
        second = self.set_version("1.0.0")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already 1.0.0", second.stdout)
        self.assert_unchanged()

    def test_invalid_versions_are_rejected_without_changes(self):
        for version in [
            "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "v1.2.3", "1.2.3-beta",
            "1.2.3+4", " 1.2.3", "1.2.3 ", "1.2.3\n", "1..3", "a.b.c", "1.2.-3", "1234567890.0.0",
        ]:
            with self.subTest(version=version):
                result = self.set_version(version)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn("is not a version", result.stderr)
                self.assert_unchanged()

    def test_wrong_arguments_print_usage(self):
        result = run([str(SET_VERSION)], cwd=self.scratch)
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)
        result = run([str(SET_VERSION), "1.0.0", str(self.project), "extra"], cwd=self.scratch)
        self.assertEqual(result.returncode, 64)
        self.assert_unchanged()

    def test_a_missing_project_fails_without_changes(self):
        result = run([str(SET_VERSION), "1.0.0", str(self.scratch / "Missing.xcodeproj")], cwd=self.scratch)
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assert_unchanged()

    def test_a_project_without_marketing_version_fails_without_changes(self):
        text = re.sub(r'\n\s*"MARKETING_VERSION": "[^"]*",', "", self.file.read_text())
        self.file.write_text(text)
        git(self.scratch, "commit", "--quiet", "-am", "no MARKETING_VERSION")
        result = self.set_version("1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no MARKETING_VERSION", result.stderr)
        self.assert_unchanged()


class WhatToTestTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="what-to-test-tests."))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.export = Path(tempfile.mkdtemp(prefix="what-to-test-export."))
        self.addCleanup(shutil.rmtree, self.export, ignore_errors=True)
        git(self.repo, "init", "--quiet")
        self.notes = self.repo / "TestFlight/WhatToTest.en-US.txt"

    def commit(self, message, changelog=None):
        if changelog is not None:
            (self.repo / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
            git(self.repo, "add", "CHANGELOG.md")
        git(self.repo, "commit", "--quiet", "--allow-empty", "-m", message)

    def post_xcodebuild(self, **overrides):
        env = {
            key: value for key, value in os.environ.items() if not key.startswith("CI_")
        }
        env.update(
            CI_XCODEBUILD_ACTION="archive",
            CI_XCODEBUILD_EXIT_CODE="0",
            CI_APP_STORE_SIGNED_APP_PATH=str(self.export),
            CI_PRIMARY_REPOSITORY_PATH=str(self.repo),
            CI_BUILD_NUMBER="42",
        )
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        result = run(["/bin/sh", str(POST_XCODEBUILD)], cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_notes_come_from_the_topmost_changelog_section(self):
        self.commit("Add things\n\nCo-authored-by: Someone <a@b.c>", changelog="""# Changelog

Intro text that is not a section.

## [Unreleased]

### Added

- Playlist editing, with a long entry that wraps
  onto a second line.
- Year in review.

### Fixed

- A crash.

## [0.9.0] - 2026-01-01

### Added

- An older entry.

[Unreleased]: https://example.com/compare/v0.9.0...HEAD
[0.9.0]: https://example.com/releases/tag/v0.9.0
""")
        result = self.post_xcodebuild()
        self.assertIn("Using the topmost CHANGELOG.md section", result.stdout)
        head = git(self.repo, "rev-parse", "--short", "HEAD").strip()
        self.assertEqual(
            self.notes.read_text(),
            f"""Build 42 ({head})

Unreleased

Added
- Playlist editing, with a long entry that wraps onto a second line.
- Year in review.

Fixed
- A crash.
""",
        )
        self.assertFalse((self.repo / "TestFlight/WhatToTest.en-US.txt.tmp").exists())

    def test_an_empty_unreleased_section_is_passed_over_for_the_release(self):
        self.commit("Release", changelog="""# Changelog

## [Unreleased]

## [1.0.0] - 2026-11-12

### Added

- The first release.

## [0.9.0] - 2026-01-01

- Older.

[Unreleased]: https://example.com/compare/v1.0.0...HEAD
""")
        self.post_xcodebuild()
        notes = self.notes.read_text()
        self.assertIn("\n\n1.0.0 - 2026-11-12\n\nAdded\n- The first release.\n", notes)
        self.assertNotIn("Unreleased", notes)
        self.assertNotIn("Older", notes)

    def test_long_notes_are_cut_at_a_line_break_within_the_limit(self):
        entries = "".join(f"- Entry {index:03d} é with some words to fill the line.\n" for index in range(200))
        self.commit("Long", changelog=f"# Changelog\n\n## [Unreleased]\n\n### Added\n\n{entries}")
        self.post_xcodebuild()
        data = self.notes.read_bytes()
        self.assertLessEqual(len(data), MAX_NOTES_BYTES)
        self.assertGreater(len(data), MAX_NOTES_BYTES - 100, "the notes use most of the limit")
        self.assertTrue(data.endswith(b"\n"))
        lines = data.decode("utf-8").splitlines()
        self.assertTrue(lines[-1].endswith("to fill the line."), lines[-1])
        self.assertIn("- Entry 000 é with some words to fill the line.", lines)
        self.assertNotIn("- Entry 199 é with some words to fill the line.", lines)

    def test_without_a_changelog_the_notes_list_recent_commits(self):
        self.commit("Fix the player\n\nBody line.\n\nCo-authored-by: Someone <a@b.c>\nCopilot-Session: x")
        result = self.post_xcodebuild()
        self.assertIn("CHANGELOG.md is missing or has no entries", result.stdout)
        notes = self.notes.read_text()
        self.assertIn("- Fix the player\n  Body line.\n", notes)
        self.assertNotIn("Co-authored-by", notes)
        self.assertNotIn("Copilot-Session", notes)

    def test_a_changelog_without_entries_falls_back_to_commits(self):
        self.commit("Only commit", changelog="# Changelog\n\n## [Unreleased]\n\n### Added\n\n")
        self.post_xcodebuild()
        self.assertIn("- Only commit\n", self.notes.read_text())

    def test_only_archives_for_testflight_get_notes(self):
        self.commit("Change", changelog="# Changelog\n\n## [Unreleased]\n\n- Entry.\n")
        cases = {
            "build action": {"CI_XCODEBUILD_ACTION": "build"},
            "test action": {"CI_XCODEBUILD_ACTION": "test-without-building"},
            "no export": {"CI_APP_STORE_SIGNED_APP_PATH": None},
            "missing export": {"CI_APP_STORE_SIGNED_APP_PATH": str(self.repo / "missing")},
            "failed build": {"CI_XCODEBUILD_EXIT_CODE": "65"},
            "no repository path": {"CI_PRIMARY_REPOSITORY_PATH": None},
        }
        for name, overrides in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.repo / "TestFlight", ignore_errors=True)
                result = self.post_xcodebuild(**overrides)
                self.assertIn("Skipping What to Test notes", result.stdout)
                self.assertFalse((self.repo / "TestFlight").exists())


class ReleaseTagTests(unittest.TestCase):
    """ci_post_clone.sh fails a tag build whose v<x.y.z> tag doesn't match MARKETING_VERSION."""

    VERSION = "1.2.3"

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="release-tag-tests."))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        project = self.repo / "Audiobookshelf.xcodeproj"
        project.mkdir()
        self.file = project / "project.xcproj"
        text, count = re.subn(
            r'("MARKETING_VERSION(?:\[[^\]]*\])*": )"[^"]*"',
            rf'\1"{self.VERSION}"',
            (PROJECT / "project.xcproj").read_text(),
        )
        self.assertGreaterEqual(count, 3)
        self.file.write_text(text)
        git(self.repo, "init", "--quiet")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "--quiet", "-m", "baseline")
        # A stub xcodebuild, so the tests need no Xcode and show whether the script got past
        # the check.
        self.bin = self.repo / ".bin"
        self.bin.mkdir()
        self.xcodebuild_log = self.repo / ".xcodebuild.log"
        stub = self.bin / "xcodebuild"
        stub.write_text(f'#!/bin/sh\necho "$@" >> "{self.xcodebuild_log}"\necho "Xcode 27.2"\n')
        stub.chmod(0o755)

    def post_clone(self, tag):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("CI_", "ABS_"))}
        env.update(PATH=f"{self.bin}:{env.get('PATH', '/usr/bin:/bin')}", CI_PRIMARY_REPOSITORY_PATH=str(self.repo))
        if tag is not None:
            env["CI_TAG"] = tag
        return run(["/bin/sh", str(POST_CLONE)], cwd=self.repo, env=env)

    def assert_passes(self, tag):
        result = self.post_clone(tag)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.xcodebuild_log.exists(), "the build goes on")
        return result

    def assert_fails(self, tag, message):
        result = self.post_clone(tag)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.xcodebuild_log.exists(), "the check fails before anything else runs")
        return result

    def test_a_branch_build_is_not_checked(self):
        for tag in (None, ""):
            with self.subTest(tag=tag):
                result = self.assert_passes(tag)
                self.assertNotIn("MARKETING_VERSION", result.stdout + result.stderr)

    def test_a_matching_tag_passes(self):
        result = self.assert_passes(f"v{self.VERSION}")
        self.assertIn(f"Release tag v{self.VERSION} matches MARKETING_VERSION {self.VERSION}", result.stdout)

    def test_a_mismatched_tag_fails(self):
        for tag in ("v1.2.4", "v1.3.3", "v2.2.3", "v0.0.0"):
            with self.subTest(tag=tag):
                result = self.assert_fails(tag, f"release tag {tag} doesn't match MARKETING_VERSION ({self.VERSION})")
                self.assertIn(f"mise run release:version {tag[1:]}", result.stderr)

    def test_tags_that_are_not_release_tags_are_ignored(self):
        for tag in ("nightly", "release-1.2.4", "1.2.4", "v", "vNext", "V1.2.4"):
            with self.subTest(tag=tag):
                self.xcodebuild_log.unlink(missing_ok=True)
                result = self.assert_passes(tag)
                self.assertIn(f"CI_TAG {tag} is not a release tag", result.stdout)

    def test_malformed_version_tags_fail(self):
        for tag in (
            "v1.2", "v1.2.3.4", "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3-beta", "v0.9.1-beta",
            "v1.2.3+4", "v1.2.3 ", "v1.2.3\n", "v1..3", "v1234567890.0.0", f"v{self.VERSION}\nv{self.VERSION}",
        ):
            with self.subTest(tag=tag):
                self.assert_fails(tag, "is not v<MAJOR.MINOR.PATCH>")

    def test_every_setting_must_match_including_conditional_ones(self):
        text = self.file.read_text()
        anchor = '    "MACOSX_DEPLOYMENT_TARGET": "27.0",\n'
        self.assertIn(anchor, text)
        self.file.write_text(text.replace(anchor, anchor + '    "MARKETING_VERSION[config=Debug]": "1.2.4",\n'))
        self.assert_fails(f"v{self.VERSION}", "doesn't match MARKETING_VERSION (1.2.3 1.2.4)")

    def add_setting(self, line):
        text = self.file.read_text()
        anchor = '    "MACOSX_DEPLOYMENT_TARGET": "27.0",\n'
        self.assertIn(anchor, text)
        self.file.write_text(text.replace(anchor, anchor + line, 1))

    def test_an_array_override_that_differs_fails(self):
        for line in (
            '    "MARKETING_VERSION[config=Release]": ["1.2.4"],\n',
            '    "MARKETING_VERSION[config=Release]": [ "1.2.4", ],\n',
            '    "MARKETING_VERSION[sdk=macosx*]": [\n      "1.2.4",\n    ],\n',
        ):
            with self.subTest(line=line):
                self.setUp()
                self.add_setting(line)
                self.assert_fails(f"v{self.VERSION}", "doesn't match MARKETING_VERSION (1.2.3 1.2.4)")

    def test_a_matching_one_string_array_passes(self):
        for line in (
            f'    "MARKETING_VERSION[config=Release]": ["{self.VERSION}"],\n',
            f'    "MARKETING_VERSION[sdk=macosx*]": [\n      "{self.VERSION}",\n    ],\n',
        ):
            with self.subTest(line=line):
                self.setUp()
                self.add_setting(line)
                self.assert_passes(f"v{self.VERSION}")

    def test_an_unsupported_value_fails(self):
        for line in (
            f'    "MARKETING_VERSION[config=Release]": ["{self.VERSION}", "1.2.4"],\n',
            f'    "MARKETING_VERSION[config=Release]": ["{self.VERSION}", "{self.VERSION}"],\n',
            '    "MARKETING_VERSION[config=Release]": [],\n',
            '    "MARKETING_VERSION[config=Release]": 1.2,\n',
            '    "MARKETING_VERSION[config=Release]": "",\n',
            '    "MARKETING_VERSION[config=Release]": "1.2.\\u0033",\n',
            '    "MARKETING_VERSION[config=Release]": { "value": "1.2.3" },\n',
        ):
            with self.subTest(line=line):
                self.setUp()
                self.add_setting(line)
                self.assert_fails(
                    f"v{self.VERSION}", 'unsupported MARKETING_VERSION value for "MARKETING_VERSION[config=Release]"')

    def test_a_project_without_marketing_version_fails(self):
        self.file.write_text(re.sub(r'\n\s*"MARKETING_VERSION": "[^"]*",', "", self.file.read_text()))
        self.assert_fails(f"v{self.VERSION}", "no MARKETING_VERSION setting")

    def test_a_missing_project_fails(self):
        self.file.unlink()
        self.assert_fails(f"v{self.VERSION}", "not found")

    def test_the_repository_project_is_read(self):
        # The real project, unpinned: the check reads its canonical layout.
        versions = set(re.findall(r'"MARKETING_VERSION(?:\[[^\]]*\])*": "([^"]*)"', (PROJECT / "project.xcproj").read_text()))
        self.assertEqual(len(versions), 1, versions)
        shutil.copy2(PROJECT / "project.xcproj", self.file)
        self.assert_passes(f"v{versions.pop()}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
