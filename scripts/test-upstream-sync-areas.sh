#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upstream-sync-areas.sh
source "$SCRIPT_DIR/upstream-sync-areas.sh"

check_area() {
  local path="$1" expected="$2"
  classify "$path"
  # shellcheck disable=SC2154 # classify sets this in the sourced helper.
  if [[ "$area" != "$expected" ]]; then
    echo "Expected $path in area $expected, got $area" >&2
    exit 1
  fi
}

check_area "ios/App/Shared/player/AudioPlayer.swift" 1
check_area "store/player.js" 1
check_area "ios/App/App/plugins/AbsDownloader.swift" 2
check_area "components/download/DownloadItem.vue" 2
check_area "ios/App/Shared/util/ApiClient.swift" 3
check_area "middleware/auth.js" 3
check_area "pages/library.vue" 4
check_area "ios/App/Shared/util/Database.swift" 5
check_area "store/settings.js" 6
check_area "strings/de.json" 7
check_area "android/app/src/Main.java" 8
check_area ".github/workflows/build.yml" 9
check_area "unclassified.txt" 10

echo "upstream path classification passed"
