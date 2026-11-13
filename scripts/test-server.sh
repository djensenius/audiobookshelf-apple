#!/usr/bin/env bash
# Opt-in contract tests against a real Audiobookshelf server (docs/testing/server-contracts.md).
#
#   scripts/test-server.sh test [swift test args]   seed a server, run ABSServerContractTests, tear down
#   scripts/test-server.sh serve                    seed a server and keep it running for manual use
#
# ABS_SERVER_VERSION  server release to run (default 2.26.0, the minimum supported version)
# ABS_SERVER_BACKEND  docker (default), or node: the source release on Node 20, for runners without
#                     Docker (run as: mise exec node@20 -- scripts/test-server.sh)
# ABS_SERVER_TIMEOUT  seconds to wait for startup and for the first scan (default 120)
#
# Everything lives in one temporary directory with a random root password; the trap verifies
# server shutdown before deleting data, retaining it and failing if containment is uncertain.
# The server runs with RATE_LIMIT_AUTH_MAX=0: its
# default of 40 /login and /auth/refresh calls per 10 minutes would end the suite with 429s.
# Runs on macOS /bin/bash 3.2.
set -euo pipefail

cd "$(dirname "$0")/.."

version=${ABS_SERVER_VERSION:-2.26.0}
backend=${ABS_SERVER_BACKEND:-docker}
timeout=${ABS_SERVER_TIMEOUT:-120}
username=root

work=
container=
container_requested=0
container_name=
server_pid=
server_log=
base_url=
books_folder=
podcasts_folder=
password=
token=
search_contract=0
search_only=0
search_token=
search_root=
search_provenance=
# Never inherit permission to run owned-search writes from an ad-hoc invocation.
unset ABS_SEARCH_CONTRACT_MODE ABS_SEARCH_OWNERSHIP ABS_SEARCH_OWNED_URL ABS_SEARCH_BOOKS \
  ABS_SEARCH_PODCASTS ABS_SEARCH_TOKEN ABS_SEARCH_PROVENANCE

log() { printf '==> %s\n' "$*" >&2; }

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required: $2"
}

# shellcheck source=scripts/test-server-cleanup.sh
source scripts/test-server-cleanup.sh

show_server_log() {
  [[ -n "$container$server_log" ]] || return 0
  echo "--- last server log lines ---" >&2
  if [[ -n "$container" ]]; then
    [[ "$container" =~ ^[0-9a-f]{64}$ ]] || return 0
    bounded_command "$cleanup_command_timeout" docker logs --tail 40 "$container" || true
  else
    bounded_command "$cleanup_command_timeout" tail -n 40 "$server_log" || true
  fi
  printf '%s' "$bounded_output" >&2
}

cleanup() {
  local status=$? contained=1
  trap '' INT TERM
  trap - EXIT
  if [[ -z "$container" && -n "$work" && -f "$work/container.id" ]]; then
    IFS= read -r container <"$work/container.id" || true
  fi
  if ((status != 0 && status != 130 && status != 143)); then show_server_log; fi
  if [[ -n "$container" ]]; then
    if ! stop_owned_docker; then contained=0; fi
  elif ((container_requested)); then
    log "Missing registered container ID for requested name=$container_name; shutdown cannot be verified"
    contained=0
  fi
  if [[ -n "$server_pid" ]]; then
    if ! stop_owned_node; then contained=0; fi
  fi
  if ((contained)); then
    if [[ -n "$work" ]] && ! rm -rf "$work"; then
      log "Could not remove stopped server's owned directory: $work"
      if ((status == 0)); then status=1; fi
    fi
  else
    log "CONTAINMENT UNVERIFIED: container ID=$container PID=$server_pid; retaining owned data: $work"
    if ((status == 0)); then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mode=${1:-test}
case "$mode" in
  test | serve) shift || true ;;
  *)
    echo "usage: scripts/test-server.sh [test [swift test args...] | serve]" >&2
    exit 64
    ;;
esac
if [[ "$mode" == test ]]; then
  if (($# == 0)); then search_contract=1; fi
  if [[ "${1:-}" == --search-contract ]]; then
    (($# == 1)) || die "--search-contract runs only the owned search suite; do not combine it with Swift arguments"
    search_contract=1
    search_only=1
    shift
  fi
fi

expected_revision=
expected_digest=
if ((search_contract)); then
  case "$version" in
    2.26.0)
      expected_revision=264ae928a9c1af620487488110eec816b14e23ec
      expected_digest=sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5 ;;
    2.37.2)
      expected_revision=edb1f7efc92ecacdef51aafb4d9d5054ce10604f
      expected_digest=sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa ;;
    *) die "owned search requires a reviewed source pin for $version" ;;
  esac
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ABS_SERVER_VERSION must look like 2.26.0 (got '$version')"
[[ "$timeout" =~ ^[0-9]+$ ]] || die "ABS_SERVER_TIMEOUT must be a number of seconds (got '$timeout')"
[[ "$backend" == docker || "$backend" == node ]] || die "ABS_SERVER_BACKEND must be docker or node (got '$backend')"
require curl "it is part of macOS"
require openssl "it is part of macOS"
require plutil "this script needs macOS"
require ffmpeg "install it with: brew install ffmpeg"

# api METHOD PATH [BODY [BEARER-TOKEN]] prints the response body and fails on an HTTP error.
# The body goes in on stdin, so the password never appears in the process list.
api() {
  local args=(--silent --show-error --fail-with-body --max-time 30 --request "$1"
    --header "x-return-tokens: true" --header "Content-Type: application/json")
  if [[ -n "${4:-}" ]]; then args+=(--header "Authorization: Bearer $4"); fi
  if [[ -n "${3:-}" ]]; then
    printf '%s' "$3" | curl "${args[@]}" --data-binary @- "$base_url$2"
  else
    curl "${args[@]}" "$base_url$2"
  fi
}

# json_get KEY-PATH JSON prints one value, for example user.accessToken or results.0.id.
json_get() {
  printf '%s' "$2" | plutil -extract "$1" raw -o - - 2>/dev/null
}

# tone OUTPUT HERTZ SECONDS FFMPEG-OPTIONS... writes a synthetic sine tone.
tone() {
  local out=$1 hertz=$2 seconds=$3
  shift 3
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=$hertz:duration=$seconds:sample_rate=16000" -ac 1 "$@" "$out"
}

# Two books and one podcast. The tracks are long enough (>= 20 s) that the server's auto-finish
# rule (less than 10 s left) doesn't finish an item the tests have just started.
make_media() {
  local tale="$work/audiobooks/Ada Fixture/The Synthetic Tale"
  local single="$work/audiobooks/Ada Fixture/Single File Tale"
  local cast="$work/podcasts/Synthetic Cast"
  local mp3=(-c:a libmp3lame -b:a 16k)
  mkdir -p "$tale" "$single" "$cast"
  tone "$tale/01 - Part One.mp3" 440 30 "${mp3[@]}" -metadata title="Part One" \
    -metadata artist="Ada Fixture" -metadata album="The Synthetic Tale" -metadata track=1/2
  tone "$tale/02 - Part Two.mp3" 523 20 "${mp3[@]}" -metadata title="Part Two" \
    -metadata artist="Ada Fixture" -metadata album="The Synthetic Tale" -metadata track=2/2
  tone "$cast/Episode One.mp3" 392 20 "${mp3[@]}" -metadata title="Episode One" \
    -metadata artist="Synthetic Cast" -metadata album="Synthetic Cast" -metadata genre=Podcast
  printf ';FFMETADATA1\ntitle=Single File Tale\nartist=Ada Fixture\nalbum=Single File Tale\n' >"$work/chapters.ffmeta"
  local chapter
  for chapter in "0 10000 Opening" "10000 25000 Middle" "25000 40000 Ending"; do
    # shellcheck disable=SC2086 # split into start, end and title on purpose
    set -- $chapter
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%s\nEND=%s\ntitle=%s\n' "$1" "$2" "$3" >>"$work/chapters.ffmeta"
  done
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=330:duration=40:sample_rate=16000" -i "$work/chapters.ffmeta" \
    -map 0:a -map_metadata 1 -map_chapters 1 -ac 1 -c:a aac -b:a 16k -f ipod "$single/Single File Tale.m4b"
}

make_search_media() {
  search_token="search$(openssl rand -hex 8)"
  local mp3=(-c:a libmp3lame -b:a 16k) number
  # Not inside/equal to/a prefix variant of either seed root. Each file is generated independently.
  mkdir -p "$work/search-fixtures/books/First" "$work/search-fixtures/books/Second" \
    "$work/search-fixtures/casts/Owned Cast"
  tone "$work/search-fixtures/books/First/First.mp3" 440 30 "${mp3[@]}" \
    -metadata title="First" -metadata album="First" -metadata artist="$search_token Shared Author"
  tone "$work/search-fixtures/books/Second/Second.mp3" 523 40 "${mp3[@]}" \
    -metadata title="Second" -metadata album="Second" -metadata artist="$search_token Shared Author"
  # Scan primes the filter cache before PATCHes. Seed the final tags/genres/narrators
  # at scan time; retain Shared Author from ID3 and let PATCH add authors/series.
  printf '{"tags":["%s Shared Tag","%s Unique Tag"],"genres":["%s Shared Genre","%s Unique Genre"],"narrators":["%s Shared Narrator","%s Unique Narrator"],"publisher":"First Publisher","language":"en","publishedYear":"1984"}\n' \
    "$search_token" "$search_token" "$search_token" "$search_token" "$search_token" "$search_token" \
    >"$work/search-fixtures/books/First/metadata.json"
  printf '{"tags":["%s Shared Tag"],"genres":["%s Shared Genre"],"narrators":["%s Shared Narrator"],"publisher":"Second Publisher","language":"fr","publishedYear":"2007"}\n' \
    "$search_token" "$search_token" "$search_token" >"$work/search-fixtures/books/Second/metadata.json"
  printf '{"tags":["%s Podcast Tag"],"genres":["%s Podcast Genre"],"language":"de"}\n' \
    "$search_token" "$search_token" >"$work/search-fixtures/casts/Owned Cast/metadata.json"
  for number in 1 2; do
    tone "$work/search-fixtures/casts/Owned Cast/$search_token Episode $number.mp3" 392 "$((20 * number))" \
      "${mp3[@]}" -metadata title="$search_token Episode $number" \
      -metadata album="Owned Cast" -metadata artist="Owned Cast" -metadata genre="$search_token Podcast Genre"
  done
}

start_docker() {
  require docker "install Docker or OrbStack, or set ABS_SERVER_BACKEND=node"
  docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
  local image="ghcr.io/advplyr/audiobookshelf:$version"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "Pulling $image"
    docker pull --quiet "$image" >/dev/null || die "could not pull $image; is $version a published release?"
  fi
  local mounts=()
  if ((search_contract)); then
    local revision digests labels
    revision=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
    digests=$(docker image inspect "$image" --format '{{json .RepoDigests}}')
    labels=$(docker image inspect "$image" --format '{{json .Config.Labels}}')
    [[ "$revision" == "$expected_revision" ]] || die "official image revision missing or mismatched: $revision"
    [[ "$digests" == *"ghcr.io/advplyr/audiobookshelf@$expected_digest"* ]] || die "official image digest mismatch: $digests"
    log "Verified official image: $digests $labels"
    search_provenance="{\"backend\":\"docker\",\"digests\":$digests,\"labels\":$labels,\"revision\":\"$revision\"}"
    mounts+=(--volume "$work/search-fixtures:/search-fixtures:rw")
    search_root=/search-fixtures
  fi
  container_name="abs-contract-$(openssl rand -hex 4)"
  container_requested=1
  log "Starting $image as $container_name"
  docker run --detach --name "$container_name" --cidfile "$work/container.id" --label abs-contract-test=1 \
    --user "$(id -u):$(id -g)" --publish 127.0.0.1::80 --env TZ=UTC --env RATE_LIMIT_AUTH_MAX=0 \
    --volume "$work/config:/config" --volume "$work/metadata:/metadata" \
    --volume "$work/audiobooks:/audiobooks" --volume "$work/podcasts:/podcasts" \
    ${mounts[@]+"${mounts[@]}"} "$image" >/dev/null || die "could not start $image"
  IFS= read -r container <"$work/container.id" || [[ -n "$container" ]]
  [[ "$container" =~ ^[0-9a-f]{64}$ ]] || die "Docker did not register a full owned container ID"
  local mapping
  mapping=$(docker port "$container" 80/tcp)
  mapping=${mapping%%$'\n'*}
  base_url="http://127.0.0.1:${mapping##*:}"
  books_folder=/audiobooks
  podcasts_folder=/podcasts
}

start_node() {
  require git "it is needed to fetch the server source"
  require node "run this as: mise exec node@20 -- scripts/test-server.sh"
  require ffprobe "it comes with ffmpeg"
  local major npm
  major=$(node -p 'process.versions.node.split(".")[0]')
  [[ "$major" == 20 ]] || die "the node backend needs Node 20, found $(node --version); use: mise exec node@20 -- scripts/test-server.sh"
  # The npm that ships with this Node. Another npm earlier on PATH may not support Node 20 and
  # may skip the install scripts that fetch the sqlite3 binary.
  npm="$(dirname "$(command -v node)")/npm"
  [[ -x "$npm" ]] || die "no npm next to $(command -v node)"
  log "Fetching Audiobookshelf v$version"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$version" \
    https://github.com/advplyr/audiobookshelf.git "$work/server" || die "could not clone Audiobookshelf v$version"
  if ((search_contract)); then
    local revision
    revision=$(git -C "$work/server" rev-parse HEAD)
    [[ "$revision" == "$expected_revision" ]] || die "node checkout revision mismatch: $revision"
    [[ -z "$(git -C "$work/server" status --porcelain)" ]] || die "node source checkout is not clean"
    log "Verified node checkout: $revision (clean)"
    search_provenance="{\"backend\":\"node\",\"revision\":\"$revision\",\"checkoutClean\":true}"
    search_root="$work/search-fixtures"
  fi
  log "Installing server dependencies"
  # `npm ci` rejects the lock file on macOS: it was written on Linux and has no entry for fsevents.
  # The cache lives in the work directory so a run leaves nothing in ~/.npm.
  (cd "$work/server" && "$npm" install --omit=dev --no-audit --no-fund --loglevel=error --cache "$work/npm-cache") ||
    die "npm install failed"
  local port
  port=$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close() })')
  base_url="http://127.0.0.1:$port"
  books_folder="$work/audiobooks"
  podcasts_folder="$work/podcasts"
  server_log="$work/server.log"
  log "Starting Audiobookshelf v$version on port $port"
  (
    cd "$work/server"
    NODE_ENV=production HOST=127.0.0.1 PORT="$port" CONFIG_PATH="$work/config" METADATA_PATH="$work/metadata" \
      RATE_LIMIT_AUTH_MAX=0 SKIP_BINARIES_CHECK=1 FFMPEG_PATH="$(command -v ffmpeg)" FFPROBE_PATH="$(command -v ffprobe)" \
      exec node index.js
  ) >"$server_log" 2>&1 &
  server_pid=$!
}

server_is_running() {
  if [[ -n "$container" ]]; then
    [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]
  else
    kill -0 "$server_pid" 2>/dev/null
  fi
}

wait_for_ping() {
  local deadline=$((SECONDS + timeout))
  until curl --silent --fail --max-time 2 "$base_url/ping" >/dev/null 2>&1; do
    server_is_running || die "the server exited before it answered /ping"
    ((SECONDS < deadline)) || die "the server did not answer /ping within ${timeout}s"
    sleep 0.5
  done
}

# create_library NAME FOLDER MEDIA-TYPE ICON prints the new library's id.
create_library() {
  local reply
  reply=$(api POST /api/libraries "$(printf '{"name":"%s","folders":[{"fullPath":"%s"}],"mediaType":"%s","icon":"%s"}' "$1" "$2" "$3" "$4")" "$token") ||
    die "could not create the $1 library: $reply"
  json_get id "$reply" || die "the $1 library response had no id: $reply"
}

# wait_for_items LIBRARY-ID COUNT LABEL polls until the scan has found COUNT items. The scan
# endpoint answers before the scan finishes.
wait_for_items() {
  local deadline=$((SECONDS + timeout)) total=0 reply
  api POST "/api/libraries/$1/scan" "" "$token" >/dev/null || die "could not start the $3 scan"
  while :; do
    reply=$(api GET "/api/libraries/$1/items?limit=1&minified=1" "" "$token") || die "could not list the $3 items: $reply"
    total=$(json_get total "$reply" || echo 0)
    if ((total >= $2)); then return 0; fi
    ((SECONDS < deadline)) || die "timed out after ${timeout}s: the $3 scan found $total of $2 items"
    sleep 1
  done
}

seed_server() {
  local reply credentials books podcasts
  credentials=$(printf '{"username":"%s","password":"%s"}' "$username" "$password")
  reply=$(api POST /init "$(printf '{"newRoot":%s}' "$credentials")") || die "could not create the root user: $reply"
  reply=$(api POST /login "$credentials") || die "could not log in as $username: $reply"
  token=$(json_get user.accessToken "$reply") || die "the login response had no access token"
  books=$(create_library "Books" "$books_folder" book audiobookshelf)
  podcasts=$(create_library "Podcasts" "$podcasts_folder" podcast podcast)
  wait_for_items "$books" 2 book
  wait_for_items "$podcasts" 1 podcast
}

work=$(mktemp -d "${TMPDIR:-/tmp}/abs-contract.XXXXXX")
# The real path: a symlinked one (/var on macOS) confuses the server's scanner.
work=$(cd "$work" && pwd -P)
mkdir -p "$work/config" "$work/metadata"
password=$(openssl rand -hex 16)
log "Generating synthetic audio"
make_media
if ((search_contract)); then make_search_media; fi
if [[ "$backend" == docker ]]; then start_docker; else start_node; fi
wait_for_ping
if ((search_contract)); then
  status=$(api GET /status)
  [[ "$(json_get serverVersion "$status")" == "$version" ]] || die "actual /status version mismatch: $status"
  log "Verified actual /status: $status"
fi
log "Seeding Audiobookshelf $version at $base_url"
seed_server

if [[ "$mode" == serve ]]; then
  printf 'Audiobookshelf %s is running.\n  URL:      %s\n  Username: %s\n  Password: %s\nPress Ctrl-C to stop it and delete its data.\n' \
    "$version" "$base_url" "$username" "$password"
  while :; do sleep 1; done
fi

export ABS_TEST_SERVER_URL="$base_url" ABS_TEST_USERNAME="$username" ABS_TEST_PASSWORD="$password"
export ABS_TEST_SERVER_VERSION="$version"
if ((search_contract)); then
  if ((!search_only)); then
    log "Ordinary pass: --filter ABSServerContractTests --skip SearchContractTests"
    ABS_PODCAST_WRITE_CONTRACT='' swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm \
      --filter ABSServerContractTests --skip SearchContractTests
    # Creating podcasts changes the seeded podcast library that ordinary suites count, so it runs alone.
    log "Podcast write pass: --filter PodcastCreationContractTests"
    ABS_PODCAST_WRITE_CONTRACT=1 swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm \
      --filter PodcastCreationContractTests
  fi
  # Export only for the second process, after ordinary suites have finished successfully.
  export ABS_SEARCH_CONTRACT_MODE=1 ABS_SEARCH_OWNERSHIP="$search_token" ABS_SEARCH_OWNED_URL="$base_url"
  export ABS_SEARCH_BOOKS="$search_root/books" ABS_SEARCH_PODCASTS="$search_root/casts"
  export ABS_SEARCH_TOKEN="$search_token" ABS_SEARCH_PROVENANCE="$search_provenance"
  log "Owned search pass: --filter SearchContractTests"
  swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm --filter SearchContractTests
else
  log "Running the selected contract tests (owned search disabled)"
  swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm "$@"
fi
log "Done in ${SECONDS}s"
