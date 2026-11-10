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

if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$PINNED_SHA" || ! -x "$bin" ]]; then
  echo "Building xcprojformatter at $PINNED_SHA…" >&2
  rm -rf "$src"
  mkdir -p "$src"
  git -C "$src" init --quiet
  git -C "$src" fetch --quiet --depth 1 "$REPO_URL" "$PINNED_SHA"
  git -C "$src" checkout --quiet --detach FETCH_HEAD
  swift build --package-path "$src" -c release --product xcprojformatter >&2
fi

exec "$bin" "$@"
