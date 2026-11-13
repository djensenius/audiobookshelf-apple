#!/bin/sh
# Xcode Cloud post-clone script. See docs/release.md.
#
# The Xcode Cloud build needs no extra tools: the app uses only Apple frameworks and
# a local Swift package, and no build phase calls mise. So this script installs
# nothing. If a later change needs mise here, install a pinned release and verify
# its SHA-256 before running it; don't pipe an unpinned installer into a shell.
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

# A release tag must match the version the build ships (docs/release.md › Releasing a
# version). Branch builds have no CI_TAG. A tag that doesn't start with "v" and a digit
# isn't a release tag and is ignored. Any other must be exactly v<MAJOR.MINOR.PATCH>, as
# scripts/set-version.sh accepts, and equal every MARKETING_VERSION setting (conditional
# ones too) in project.xcproj, which keeps one setting per line in its canonical form.
check_release_tag() {
  tag="${CI_TAG:-}"
  case "$tag" in
    "") return 0 ;;
    v[0-9]*) ;;
    *)
      echo "CI_TAG $tag is not a release tag (v<x.y.z>); not checking MARKETING_VERSION"
      return 0
      ;;
  esac
  version="${tag#v}"
  case "$version" in
    *[!0-9.]*) valid=0 ;;
    *) valid=1 ;;
  esac
  if [ "$valid" = 0 ] || ! printf '%s\n' "$version" |
    grep -Eqx '(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})'; then
    echo "error: release tag $tag is not v<MAJOR.MINOR.PATCH> (no leading zeros or suffixes)" >&2
    exit 1
  fi
  project="$repo_root/Audiobookshelf.xcodeproj/project.xcproj"
  if [ ! -f "$project" ]; then
    echo "error: $project not found; can't check release tag $tag" >&2
    exit 1
  fi
  versions="$(sed -nE 's/^[[:space:]]*"MARKETING_VERSION(\[[^]]*\])*"[[:space:]]*:[[:space:]]*"([^"]*)".*/\2/p' \
    "$project" | sort -u)"
  if [ -z "$versions" ]; then
    echo "error: no MARKETING_VERSION setting in $project; can't check release tag $tag" >&2
    exit 1
  fi
  if [ "$versions" != "$version" ]; then
    found="$(printf '%s' "$versions" | tr '\n' ' ')"
    echo "error: release tag $tag doesn't match MARKETING_VERSION ($found) in project.xcproj." >&2
    echo "Run mise run release:version $version on main, merge it, and tag that commit." >&2
    exit 1
  fi
  echo "Release tag $tag matches MARKETING_VERSION $version"
}
check_release_tag

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
