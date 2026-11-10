#!/usr/bin/env bash
# Run Apple's xcprojformatter (https://github.com/apple/xcode-project-format), building
# it at a pinned commit into .build/tools on first use. Arguments pass through, e.g.:
#   scripts/xcprojformatter.sh Audiobookshelf.xcodeproj           # print canonical form
#   scripts/xcprojformatter.sh --update Audiobookshelf.xcodeproj  # rewrite in place
set -euo pipefail

readonly REPO_URL="https://github.com/apple/xcode-project-format.git"
readonly PINNED_SHA="0a7242a207038472e4a36b29bffb135b94792410"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/.build/tools/xcode-project-format"
bin="$src/.build/release/xcprojformatter"
lock="$root/.build/tools/xcode-project-format.lock"

# Re-exit with the original status: macOS /bin/bash 3.2 otherwise reports the trap's status.
release_lock() {
  local status=$?
  rmdir "$lock" 2>/dev/null || true
  exit "$status"
}

is_built() {
  [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" == "$PINNED_SHA" && -x "$bin" ]]
}

if ! is_built; then
  # Serialize builds so concurrent runs in one worktree don't clobber each other.
  mkdir -p "$(dirname "$lock")"
  if ! mkdir "$lock" 2>/dev/null; then
    echo "Waiting for another xcprojformatter build (remove ${lock} if stale)..." >&2
    until mkdir "$lock" 2>/dev/null; do sleep 2; done
  fi
  trap release_lock EXIT

  if ! is_built; then
    echo "Building xcprojformatter at ${PINNED_SHA}..." >&2
    rm -rf "$src"
    mkdir -p "$src"
    git -C "$src" init --quiet
    git -C "$src" fetch --quiet --depth 1 "$REPO_URL" "$PINNED_SHA"
    git -C "$src" checkout --quiet --detach FETCH_HEAD
    swift build --package-path "$src" -c release --product xcprojformatter >&2
  fi

  rmdir "$lock"
  trap - EXIT
fi

exec "$bin" "$@"
