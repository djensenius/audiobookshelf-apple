#!/usr/bin/env bash
# ADR 0006 (docs/adr/0006-now-playing.md): the NowPlaying framework is the only Now Playing API.
# - MediaPlayer (and its Now Playing symbols) is banned in every native source.
# - NowPlaying / _NowPlaying_AppIntents may be imported only under ABSPlayback/NowPlaying/ and its
#   tests, ABSPlaybackTests/NowPlaying/.
# Scans the app, its tests, the shared and widget/extension folders, Packages and Tools; legacy ios/ still imports
# MediaPlayer and is not scanned. Lines whose first token is a comment marker (//, /*, *) are
# skipped for the MediaPlayer ban. Fails if grep itself errors (exit > 1). Runs on macOS /bin/bash 3.2 with BSD grep (grep -E only).
set -euo pipefail

cd "$(dirname "$0")/.."

dirs=()
for d in Audiobookshelf AudiobookshelfShared AudiobookshelfTests AudiobookshelfUITests AudiobookshelfWidgets Packages Tools; do
  if [[ -d "$d" ]]; then dirs+=("$d"); fi
done
if ((${#dirs[@]} == 0)); then exit 0; fi

scan=(-rnE --include='*.swift' --exclude-dir=.build --exclude-dir=DerivedData)
allowed='^Packages/AudiobookshelfKit/(Sources/ABSPlayback|Tests/ABSPlaybackTests)/NowPlaying/'
# Attributes (with arguments), an access level and a kind before `import`, as in
# `@preconcurrency @_spi(X) public import struct MediaPlayer.MPMediaItem`.
imp='^[[:space:]]*(@[_A-Za-z][_A-Za-z0-9]*(\([^)]*\))?[[:space:]]*)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
end='([.;/[:space:]]|$)'
mp_symbols='\bMP(NowPlaying|RemoteCommand|MediaItemArtwork|MediaItemProperty|AppEntityIdentifier|SkipInterval|ChangePlayback|ChangeRepeatMode|ChangeShuffleMode|FeedbackCommand|RatingCommand)[A-Za-z]*'

# Runs grep over the scan list into $matches; fails the script if grep errors (rc > 1).
matches=''
search() {
  local rc=0
  matches=$(grep "${scan[@]}" "$@" "${dirs[@]}") || rc=$?
  if ((rc > 1)); then
    echo "error: grep failed (exit $rc); cannot verify ADR 0006" >&2
    exit "$rc"
  fi
}

status=0
search -e "${imp}(MediaPlayer|_MediaPlayer_AppIntents)${end}" -e "${mp_symbols}"
if [[ -n "$matches" ]] && printf '%s\n' "$matches" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'; then
  echo "error: MediaPlayer Now Playing APIs are banned; use the NowPlaying framework (ADR 0006)" >&2
  status=1
fi
search -e "${imp}(NowPlaying|_NowPlaying_AppIntents)${end}"
if [[ -n "$matches" ]] && printf '%s\n' "$matches" | grep -vE "${allowed}"; then
  echo "error: import NowPlaying only under ABSPlayback/NowPlaying/ or ABSPlaybackTests/NowPlaying/ (ADR 0006)" >&2
  status=1
fi
exit "$status"
