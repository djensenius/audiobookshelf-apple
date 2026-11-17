#!/usr/bin/env python3
"""Check built app and extension binaries against their privacy manifests."""

import argparse
import plistlib
from pathlib import Path
import re
import subprocess
import sys


API_PATTERNS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        r"NSUserDefaults",
        r"standardUserDefaults",
        r"initWithSuiteName:",
    ),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"NSURLContentModificationDateKey",
        r"NSFileModificationDate",
        r"contentModificationDate",
        r"setAttributes:ofItemAtPath:error:",
        r"(?<![A-Za-z0-9])_?(?:stat|lstat|fstat|fstatat|fgetattrlist|getattrlist|"
        r"getattrlistbulk|getattrlistat|utimes|futimes|futimens|utimensat)(?![A-Za-z0-9])",
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"volumeAvailableCapacity(?:ForImportantUsage)?",
        r"(?<![A-Za-z0-9])_?(?:statfs|fstatfs|statvfs|fstatvfs|getfsstat|getmntinfo)(?![A-Za-z0-9])",
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        r"systemUptime",
        r"mach_absolute_time",
        r"mach_continuous_time",
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        r"activeInputModes",
        r"primaryLanguage",
    ),
}
COMPILED_PATTERNS = {
    category: tuple(re.compile(pattern) for pattern in patterns)
    for category, patterns in API_PATTERNS.items()
}


def detected_categories(binary_output):
    """Return required-reason categories whose API symbols/selectors occur in output."""
    return {
        category
        for category, patterns in COMPILED_PATTERNS.items()
        if any(pattern.search(binary_output) for pattern in patterns)
    }


def manifest_categories(manifest):
    """Read the accessed API categories from a parsed privacy manifest."""
    if not isinstance(manifest, dict):
        raise ValueError("privacy manifest must be a dictionary")
    entries = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(entries, list):
        raise ValueError("NSPrivacyAccessedAPITypes must be an array")
    return {
        entry["NSPrivacyAccessedAPIType"]
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str)
    }


def missing_categories(detected, declared):
    return set(detected) - set(declared)


def bundle_paths(bundle):
    """Return the privacy manifest and executable path for an app or extension bundle."""
    contents = bundle / "Contents"
    if (contents / "Info.plist").is_file():
        return contents / "Resources/PrivacyInfo.xcprivacy", contents / "MacOS"
    return bundle / "PrivacyInfo.xcprivacy", bundle


def executable_paths(bundle):
    """Read bundle metadata and return its executable plus embedded debug/framework dylibs."""
    contents = bundle / "Contents"
    info_path = contents / "Info.plist" if (contents / "Info.plist").is_file() else bundle / "Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError(f"can't read {info_path}: {error}") from error

    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        raise ValueError(f"{info_path} has no CFBundleExecutable")
    _, executable_directory = bundle_paths(bundle)
    primary = executable_directory / executable
    if not primary.is_file():
        raise ValueError(f"bundle executable not found: {primary}")

    binaries = [primary]
    binaries.extend(sorted(primary.parent.glob("*.debug.dylib")))
    framework_directory = contents / "Frameworks" if contents.is_dir() else bundle / "Frameworks"
    if framework_directory.is_dir():
        binaries.extend(sorted(path for path in framework_directory.rglob("*.dylib") if path.is_file()))
    return list(dict.fromkeys(binaries))


def binary_api_output(binary):
    """Collect undefined symbols and strings from a Mach-O executable."""
    output = []
    for command in (["nm", "-u", str(binary)], ["strings", str(binary)]):
        try:
            result = subprocess.run(command, check=False, capture_output=True, text=True, errors="replace")
        except OSError as error:
            raise ValueError(f"can't run {command[0]}: {error}") from error
        if result.returncode:
            message = result.stderr.strip() or f"exit status {result.returncode}"
            raise ValueError(f"{' '.join(command)} failed: {message}")
        output.append(result.stdout)
    return "\n".join(output)


def check_bundle(bundle):
    manifest_path, _ = bundle_paths(bundle)
    try:
        with manifest_path.open("rb") as stream:
            manifest = plistlib.load(stream)
        declared = manifest_categories(manifest)
        binaries = executable_paths(bundle)
        found = set()
        owners = {}
        for binary in binaries:
            categories = detected_categories(binary_api_output(binary))
            found.update(categories)
            for category in categories:
                owners.setdefault(category, []).append(binary.name)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return [f"error: {bundle.name}: {error}"]

    missing = missing_categories(found, declared)
    if missing:
        return [
            f"error: {bundle.name} {manifest_path.name} lacks {category}; "
            f"detected in {', '.join(owners[category])}"
            for category in sorted(missing)
        ]
    categories = ", ".join(sorted(found)) if found else "no required-reason API symbols detected"
    return [f"OK: {bundle.name}: {categories}"]


def check_app(app):
    app = app.resolve()
    if not app.is_dir() or app.suffix != ".app":
        return [f"error: expected a built .app directory: {app}"]
    bundles = [app]
    plugins = app / "Contents/PlugIns" if (app / "Contents").is_dir() else app / "PlugIns"
    bundles.extend(sorted(path for path in plugins.glob("*.appex") if path.is_dir()))
    return [message for bundle in bundles for message in check_bundle(bundle)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="built .app bundle to inspect")
    args = parser.parse_args(argv)
    messages = check_app(args.app)
    for message in messages:
        print(message)
    return 1 if any(message.startswith("error:") for message in messages) else 0


if __name__ == "__main__":
    sys.exit(main())
