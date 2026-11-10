#!/bin/sh
# Xcode Cloud post-clone script. See docs/release.md.
#
# The Xcode Cloud build needs no extra tools: the app uses only Apple frameworks and
# a local Swift package, and no build phase calls mise. So this script installs
# nothing. If a later change needs mise here, install a pinned release and verify
# its SHA-256 before running it; don't pipe an unpinned installer into a shell.
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

xcodebuild -version

# Fallback if Xcode Cloud rejects the JSON project format (project.xcproj).
# Opt in by setting ABS_CONVERT_PROJECT=1 in the workflow's Environment section.
# It converts the project to the classic project.pbxproj format inside the CI
# checkout only. Never commit the converted project: the repository keeps
# project.xcproj, and Xcode refuses a project that has both files.
# `-convert-project` is listed by `xcodebuild -help` in Xcode 27.2, and
# "Xcode 16.0" is one of its accepted formats (objectVersion 110).
if [ "${ABS_CONVERT_PROJECT:-0}" = "1" ]; then
  echo "ABS_CONVERT_PROJECT=1: converting project.xcproj to project.pbxproj (CI checkout only)"
  xcodebuild -convert-project 'Xcode 16.0' -project "$repo_root/Audiobookshelf.xcodeproj"
  if [ -e "$repo_root/Audiobookshelf.xcodeproj/project.xcproj" ]; then
    echo "error: project.xcproj still exists after conversion" >&2
    exit 1
  fi
  if [ ! -s "$repo_root/Audiobookshelf.xcodeproj/project.pbxproj" ]; then
    echo "error: project.pbxproj is missing or empty after conversion" >&2
    exit 1
  fi
fi
