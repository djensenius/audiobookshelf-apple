#!/usr/bin/env bash
# Set MARKETING_VERSION (the version TestFlight and the App Store show) for every target and
# configuration in the JSON Xcode project, then rewrite it in canonical form. See
# docs/release.md. Only that setting changes; the build number is Xcode Cloud's
# CI_BUILD_NUMBER, so CURRENT_PROJECT_VERSION is left alone. Never use agvtool: it can't
# read project.xcproj.
#
#   scripts/set-version.sh 1.2.0                        # Audiobookshelf.xcodeproj
#   scripts/set-version.sh 1.2.0 path/to/Other.xcodeproj
#
# The version must be MAJOR.MINOR.PATCH without leading zeros, suffixes or build metadata:
# CFBundleShortVersionString allows only three period-separated integers. Running it again
# with the same version changes nothing. On any error the project is left untouched.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: scripts/set-version.sh <MAJOR.MINOR.PATCH> [Project.xcodeproj]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 2 ]] || usage
version="$1"
project="${2:-$root/Audiobookshelf.xcodeproj}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; then
  echo "error: '$version' is not a version like 1.2.0 (MAJOR.MINOR.PATCH, no leading zeros or suffixes)" >&2
  exit 64
fi

file="$project/project.xcproj"
if [[ ! -f "$file" ]]; then
  echo "error: $file not found" >&2
  exit 66
fi

edited="$(mktemp "${TMPDIR:-/tmp}/set-version.edited.XXXXXX")"
canonical="$(mktemp "${TMPDIR:-/tmp}/set-version.canonical.XXXXXX")"
cleanup() {
  local status=$?
  rm -f "$edited" "$canonical"
  exit "$status"
}
trap cleanup EXIT

# project.xcproj is JSON with trailing commas. Drop those (outside strings), parse it, set
# every MARKETING_VERSION key (conditional ones such as MARKETING_VERSION[sdk=macosx*] too),
# and print plain JSON; xcprojformatter then restores the canonical layout.
python3 - "$file" "$version" >"$edited" <<'PY'
import json
import re
import sys

path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

chars = []
i, n, in_string = 0, len(text), False
while i < n:
    c = text[i]
    if in_string:
        chars.append(c)
        if c == "\\" and i + 1 < n:
            chars.append(text[i + 1])
            i += 2
            continue
        if c == '"':
            in_string = False
    elif c == '"':
        in_string = True
        chars.append(c)
    elif c == ",":
        j = i + 1
        while j < n and text[j] in " \t\r\n":
            j += 1
        if j >= n or text[j] not in "]}":
            chars.append(c)
    else:
        chars.append(c)
    i += 1

try:
    project = json.loads("".join(chars))
except json.JSONDecodeError as error:
    sys.exit(f"error: cannot parse {path}: {error}")

key = re.compile(r"MARKETING_VERSION(\[[^\]]*\])*")
changed = 0


def visit(node):
    global changed
    if isinstance(node, dict):
        for name, value in node.items():
            if key.fullmatch(name) and isinstance(value, str):
                node[name] = version
                changed += 1
            else:
                visit(value)
    elif isinstance(node, list):
        for value in node:
            visit(value)


visit(project)
if changed == 0:
    sys.exit(f"error: no MARKETING_VERSION setting in {path}")
print(json.dumps(project, indent=2, ensure_ascii=False))
print(f"MARKETING_VERSION settings: {changed}", file=sys.stderr)
PY

"$root/scripts/xcprojformatter.sh" <"$edited" >"$canonical"
if cmp -s "$canonical" "$file"; then
  echo "MARKETING_VERSION is already $version in $file"
  exit 0
fi
# Write in place rather than mv, which would give the project mktemp's 0600 mode.
cat "$canonical" >"$file"
echo "Set MARKETING_VERSION to $version in $file"
