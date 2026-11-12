#!/bin/sh
# Xcode Cloud post-xcodebuild script. After an archive for TestFlight, writes the
# "What to Test" notes (TestFlight/WhatToTest.en-US.txt next to the project) from the
# topmost CHANGELOG.md section that has entries, or from recent commit messages when
# there is no such section. See docs/release.md. The notes are optional, so this
# script never fails the build.
set -eu

skip() {
  echo "Skipping What to Test notes: $1"
  exit 0
}

# Xcode Cloud runs this after every action, even a failed one. Only archives get notes.
if [ -n "${CI_XCODEBUILD_ACTION:-}" ] && [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
  skip "not an archive action ($CI_XCODEBUILD_ACTION)"
fi
# Gate on the
# App Store-signed export, as Apple's example does: it exists only after a
# successful archive whose distribution preparation targets TestFlight.
if [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ] || [ ! -d "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
  skip "no TestFlight archive (CI_APP_STORE_SIGNED_APP_PATH is not a directory)"
fi
if [ "${CI_XCODEBUILD_EXIT_CODE:-0}" != "0" ]; then
  skip "xcodebuild failed (exit code $CI_XCODEBUILD_EXIT_CODE)"
fi
if [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
  skip "CI_PRIMARY_REPOSITORY_PATH is empty or unset"
fi

MAX_COMMITS=20
# TestFlight's "What to Test" limit is 4,000 characters. Counting bytes (LC_ALL=C)
# keeps multibyte text under it too.
MAX_CHARS=4000
export LC_ALL=C

cd "$CI_PRIMARY_REPOSITORY_PATH" || skip "cannot cd to $CI_PRIMARY_REPOSITORY_PATH"
notes_dir="$CI_PRIMARY_REPOSITORY_PATH/TestFlight"
notes_file="$notes_dir/WhatToTest.en-US.txt"
tmp_file="$notes_file.tmp"

# The topmost "## " section of CHANGELOG.md (Keep a Changelog) with at least one entry:
# its title without brackets, then its "### " subheadings and entries, without blank
# lines or link reference definitions, and with wrapped entries joined into one line.
# An empty "## [Unreleased]" is passed over, so a release commit uses its version's
# section. Prints nothing when there is no such section.
changelog_section() {
  awk '
    function flush() {
      if (title != "" && has_entries) { printf "%s", buf; done = 1 }
    }
    /^## / {
      flush()
      if (done) exit
      title = $0
      sub(/^##[ \t]+/, "", title)
      gsub(/[][]/, "", title)
      buf = title "\n"
      has_entries = 0
      next
    }
    title == "" { next }
    /^[ \t]*$/ { next }
    /^\[[^]]*\]:/ { next }
    /^### / { sub(/^###[ \t]+/, ""); buf = buf "\n" $0 "\n"; next }
    # An indented line continues the entry above it: join them, as TestFlight wraps text.
    /^[ \t]+[^-* \t]/ && has_entries {
      sub(/^[ \t]+/, "")
      buf = substr(buf, 1, length(buf) - 1) " " $0 "\n"
      next
    }
    { buf = buf $0 "\n"; has_entries = 1 }
    END { if (!done) flush() }
  ' CHANGELOG.md
}

# The last MAX_COMMITS non-merge commits, subject lines first, without trailers.
commit_notes() {
  # The clone may be shallow. Deepen it so the last MAX_COMMITS commits are
  # available, without prompting or hanging; carry on with whatever history exists
  # if that fails.
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=20' \
      git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch --quiet --deepen=100 2>/dev/null ||
      echo "warning: could not deepen the clone" >&2
  fi

  # Each commit starts with a \037 marker so subjects can be told apart from bodies.
  log="$(git log --no-merges --max-count="$MAX_COMMITS" --format='%x1f%s%n%b' HEAD)" || return 1
  printf '%s\n' "$log" | awk '
    /^[ \t]*$/ { next }
    /^[ \t]*([Cc]o-[Aa]uthored-[Bb]y|[Cc]opilot-[Ss]ession|[Ss]igned-[Oo]ff-[Bb]y):/ { next }
    /^\037/ { print "- " substr($0, 2); next }
    { print "  " $0 }
  '
}

section=""
if [ -f CHANGELOG.md ]; then
  section="$(changelog_section)" || section=""
fi
if [ -n "$section" ]; then
  echo "Using the topmost CHANGELOG.md section with entries"
  body="$section"
else
  echo "CHANGELOG.md is missing or has no entries; using commit messages"
  body="$(commit_notes)" || skip "git log failed"
fi

mkdir -p "$notes_dir" || skip "cannot create $notes_dir"
if ! {
  printf 'Build %s (%s)\n\n' "${CI_BUILD_NUMBER:-?}" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '%s\n' "$body"
} | awk -v max="$MAX_CHARS" '
  { total += length($0) + 1; if (total > max) exit; print }
' >"$tmp_file"; then
  rm -f "$tmp_file"
  skip "cannot write $tmp_file"
fi
if ! mv -f "$tmp_file" "$notes_file"; then
  rm -f "$tmp_file"
  skip "cannot move the notes to $notes_file"
fi

echo "Wrote $notes_file ($(wc -c <"$notes_file" | tr -d ' ') bytes)"
