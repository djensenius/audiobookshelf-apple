#!/bin/sh
# Xcode Cloud post-xcodebuild script. For archive actions, writes the TestFlight
# "What to Test" notes (TestFlight/WhatToTest.en-US.txt next to the project) from
# recent commit messages. See docs/release.md.
set -eu

# Xcode Cloud runs this after every action, even a failed one. Only archive
# actions set CI_ARCHIVE_PATH; do nothing for the others.
if [ -z "${CI_ARCHIVE_PATH:-}" ] || [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
  exit 0
fi
if [ "${CI_XCODEBUILD_EXIT_CODE:-0}" != "0" ]; then
  exit 0
fi

MAX_COMMITS=20
# TestFlight's "What to Test" limit is 4,000 characters. Counting bytes (LC_ALL=C)
# keeps multibyte text under it too.
MAX_CHARS=4000
export LC_ALL=C

cd "$CI_PRIMARY_REPOSITORY_PATH"
notes_dir="$CI_PRIMARY_REPOSITORY_PATH/TestFlight"
notes_file="$notes_dir/WhatToTest.en-US.txt"

# The clone may be shallow. Deepen it so the log (and the previous tag, if any) is
# available; carry on with whatever history exists if that fails.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  git fetch --quiet --deepen=100 2>/dev/null || echo "warning: could not deepen the clone" >&2
fi

# Commits since the previous tag, or the last MAX_COMMITS if no tag is reachable.
range=HEAD
if previous_tag="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null)"; then
  range="$previous_tag..HEAD"
fi

# Each commit starts with a \037 marker so subjects can be told apart from bodies.
if ! log="$(git log --no-merges --max-count="$MAX_COMMITS" --format='%x1f%s%n%b' "$range")"; then
  echo "warning: git log failed; not writing TestFlight notes" >&2
  exit 0
fi

mkdir -p "$notes_dir"
{
  printf 'Build %s (%s)\n' "${CI_BUILD_NUMBER:-?}" "$(git rev-parse --short HEAD)"
  printf '%s\n' "$log" | awk '
    /^[ \t]*$/ { next }
    /^[ \t]*([Cc]o-[Aa]uthored-[Bb]y|[Cc]opilot-[Ss]ession|[Ss]igned-[Oo]ff-[Bb]y):/ { next }
    /^\037/ { print "- " substr($0, 2); next }
    { print "  " $0 }
  '
} | awk -v max="$MAX_CHARS" '
  { total += length($0) + 1; if (total > max) exit; print }
' >"$notes_file"

echo "Wrote $notes_file ($(wc -c <"$notes_file" | tr -d ' ') bytes)"
