#!/usr/bin/env bash
# Report new upstream (advplyr/audiobookshelf-app) commits as a GitHub issue.
#
# State lives in issue markers, not a mirror branch: the most recently created
# issue labelled $SYNC_LABEL whose body contains
# `<!-- upstream-sync:head=<sha> -->` records the last upstream commit that was
# reported. See docs/upstream-sync.md.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-advplyr/audiobookshelf-app}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
UPSTREAM_BASELINE="${UPSTREAM_BASELINE:-609f9d644c8390fc662869e08ace18ce4a519b00}"
SYNC_LABEL="${SYNC_LABEL:-upstream-port}"
PROJECT_OWNER="${PROJECT_OWNER:-djensenius}"
PROJECT_NUMBER="${PROJECT_NUMBER:-15}"
PROJECT_TOKEN="${PROJECT_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"
MAX_COMMITS="${MAX_COMMITS:-150}"
MAX_FILES="${MAX_FILES:-300}"
MAX_BODY_CHARS=60000

DOCS_PATH="docs/upstream-sync.md"
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
SHA_RE='^[0-9a-f]{40}$'

die() {
  echo "::error::$*" >&2
  exit 1
}

log() {
  echo "$*" >&2
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- Validate configuration -------------------------------------------------

[[ "$UPSTREAM_REPO" =~ $REPO_RE ]] || die "UPSTREAM_REPO must look like owner/repo (got '$UPSTREAM_REPO')"
[[ "$UPSTREAM_BASELINE" =~ $SHA_RE ]] || die "UPSTREAM_BASELINE must be a full 40-character commit SHA"
[[ "$MAX_COMMITS" =~ ^[1-9][0-9]*$ ]] || die "MAX_COMMITS must be a positive integer"
[[ "$MAX_FILES" =~ ^[1-9][0-9]*$ ]] || die "MAX_FILES must be a positive integer"
[[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]] || die "PROJECT_NUMBER must be a number"
case "$DRY_RUN" in
  true | false) ;;
  *) die "DRY_RUN must be 'true' or 'false' (got '$DRY_RUN')" ;;
esac

if [[ -z "${GH_REPO:-}" ]]; then
  GH_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi
[[ "$GH_REPO" =~ $REPO_RE ]] || die "GH_REPO must look like owner/repo (got '$GH_REPO')"
if [[ "$(lower "$GH_REPO")" == "$(lower "$UPSTREAM_REPO")" ]]; then
  die "GH_REPO resolved to the upstream repository ($GH_REPO); set GH_REPO to the target repository"
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- Determine the range ----------------------------------------------------

last_synced="$(
  gh issue list --repo "$GH_REPO" --label "$SYNC_LABEL" --state all --limit 100 \
    --json number,body,createdAt \
    --jq '[.[] | select((.body // "") | test("<!-- upstream-sync:head=[0-9a-f]{40} -->"))]
      | sort_by(.createdAt) | last
      | if . == null then empty else
          "\(.number) \([.body | match("<!-- upstream-sync:head=([0-9a-f]{40}) -->"; "g")] | last | .captures[0].string)"
        end'
)"

if [[ -n "$last_synced" ]]; then
  base="${last_synced#* }"
  log "Last synced upstream head: $base (from $GH_REPO#${last_synced%% *})"
else
  base="$UPSTREAM_BASELINE"
  log "No $SYNC_LABEL issue with a sync marker found; using baseline $base"
fi
[[ "$base" =~ $SHA_RE ]] || die "Could not parse the last synced head from the issue marker"

log "Fetching ${UPSTREAM_REPO} ${UPSTREAM_BRANCH}"
git fetch --quiet --no-tags "https://github.com/${UPSTREAM_REPO}.git" \
  "+refs/heads/${UPSTREAM_BRANCH}:refs/upstream-sync/head"
head="$(git rev-parse --verify 'refs/upstream-sync/head^{commit}')"

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  die "Base commit $base is not available locally. Fetch full history (fetch-depth: 0); if upstream rewrote history, see $DOCS_PATH"
fi

if [[ "$base" == "$head" ]]; then
  echo "Upstream is up to date (${UPSTREAM_REPO} ${UPSTREAM_BRANCH} at ${head:0:7})"
  summary "Upstream is up to date (\`${UPSTREAM_REPO}\` \`${UPSTREAM_BRANCH}\` at \`${head:0:7}\`)."
  exit 0
fi

if ! git merge-base --is-ancestor "$base" "$head"; then
  die "Upstream history was rewritten: $base is not an ancestor of ${UPSTREAM_REPO} ${UPSTREAM_BRANCH} ($head). Manual intervention required; see $DOCS_PATH"
fi

compare_url="https://github.com/${UPSTREAM_REPO}/compare/${base}...${head}"
commit_count="$(git rev-list --count "${base}..${head}")"
title="Upstream: port changes ${base:0:7}..${head:0:7} (${commit_count} commits)"

# --- Commits ----------------------------------------------------------------

US=$'\x1f'
ZWSP=$'\xe2\x80\x8b'

git log --reverse --date=short --format="%H${US}%s${US}%an${US}%ad" "${base}..${head}" >"$tmp/log.raw"

# Sanitize text that ends up in the issue: neutralize HTML, escape table pipes,
# point bare #123 / GH-123 references at the upstream repo, and break
# @mentions with a zero-width space so upstream users are not pinged.
LC_ALL=C sed -E \
  -e 's/</\&lt;/g' \
  -e 's/>/\&gt;/g' \
  -e 's/[|]/\\|/g' \
  -e "s~(^|[^[:alnum:]_/&])#([0-9]+)~\\1${UPSTREAM_REPO}#\\2~g" \
  -e "s~(^|[^[:alnum:]_])GH-([0-9]+)~\\1${UPSTREAM_REPO}#\\2~g" \
  -e "s/@/@${ZWSP}/g" \
  "$tmp/log.raw" >"$tmp/log"

{
  echo "| Commit | Subject | Author | Date |"
  echo "| --- | --- | --- | --- |"
  shown=0
  while IFS="$US" read -r sha subject author date; do
    if ((shown >= MAX_COMMITS)); then
      echo
      echo "_Showing the first ${MAX_COMMITS} of ${commit_count} commits; see the [full comparison](${compare_url})._"
      break
    fi
    echo "| [\`${sha:0:7}\`](https://github.com/${UPSTREAM_REPO}/commit/${sha}) | ${subject} | ${author} | ${date} |"
    shown=$((shown + 1))
  done <"$tmp/log"
} >"$tmp/commits.md"

# --- Referenced upstream pull requests --------------------------------------

cut -d "$US" -f 2 "$tmp/log.raw" |
  { grep -oE 'Merge pull request #[0-9]+|\(#[0-9]+\)' || true; } |
  { grep -oE '[0-9]+' || true; } |
  sort -n -u >"$tmp/prs"

if [[ -s "$tmp/prs" ]]; then
  while IFS= read -r pr; do
    echo "- [ ] ${UPSTREAM_REPO}#${pr}"
  done <"$tmp/prs" >"$tmp/prs.md"
else
  echo "_No pull requests referenced in commit subjects._" >"$tmp/prs.md"
fi

# --- Changed files, grouped by area -----------------------------------------

AREA_TITLES=(
  ""
  "Native iOS (Swift) — port logic to the Swift app"
  "App UI & state (Vue) — port behavior to SwiftUI"
  "Localization — re-import strings"
  "Android-only — usually not applicable"
  "Build & tooling — usually not applicable"
  "Other"
)
area_counts=(0 0 0 0 0 0 0)

classify() {
  case "$1" in
    ios/*) area=1 ;;
    pages/* | components/* | layouts/* | store/* | plugins/* | mixins/* | utils/* | objects/* | \
      middleware/* | assets/* | static/*) area=2 ;;
    strings/*) area=3 ;;
    android/*) area=4 ;;
    .github/* | fastlane/* | package.json | package-lock.json | capacitor.config.json | ionic.config.json | \
      nuxt.config.js | tailwind.config.js) area=5 ;;
    *) area=6 ;;
  esac
}

# Wrap a path or status in a Markdown code span (backticks become quotes).
code() {
  local bt='`' q="'"
  printf '%s%s%s' "$bt" "${1//"$bt"/"$q"}" "$bt"
}

file_count=0
git diff --name-status -z "$base" "$head" >"$tmp/diff"
while IFS= read -r -d '' status; do
  IFS= read -r -d '' path
  case "$status" in
    R* | C*)
      old="$path"
      IFS= read -r -d '' path
      item="- $(code "$status") $(code "$old") → $(code "$path")"
      ;;
    *)
      item="- $(code "$status") $(code "$path")"
      ;;
  esac
  classify "$path"
  area_counts[area]=$((area_counts[area] + 1))
  file_count=$((file_count + 1))
  printf '%s\n' "$item" >>"$tmp/area-$area"
done <"$tmp/diff"

{
  echo "| Area | Files |"
  echo "| --- | ---: |"
  for area in 1 2 3 4 5 6; do
    if ((area_counts[area] > 0)); then
      echo "| ${AREA_TITLES[area]} | ${area_counts[area]} |"
    fi
  done
} >"$tmp/areas.md"

{
  if ((file_count == 0)); then
    echo "_No file changes._"
  fi
  shown=0
  for area in 1 2 3 4 5 6; do
    ((area_counts[area] > 0)) || continue
    ((shown < MAX_FILES)) || break
    echo "#### ${AREA_TITLES[area]} (${area_counts[area]})"
    echo
    while IFS= read -r item; do
      ((shown < MAX_FILES)) || break
      echo "$item"
      shown=$((shown + 1))
    done <"$tmp/area-$area"
    echo
  done
  if ((file_count > MAX_FILES)); then
    echo "_Showing ${MAX_FILES} of ${file_count} changed files; see the [full comparison](${compare_url})._"
  fi
} >"$tmp/files.md"

# --- Assemble the issue body ------------------------------------------------

body="$tmp/body.md"
: >"$body"
body_len=0
budget=$((MAX_BODY_CHARS - 2000)) # room for headings, truncation notes and markers
budget_exhausted=false
TRUNCATED_NOTE="_Truncated to stay under GitHub's issue size limit; see the [full comparison](${compare_url})._"

append() {
  printf '%s\n' "$1" >>"$body"
  body_len=$((body_len + ${#1} + 1))
}

# Append a file line by line until the size budget is used up.
append_file() {
  local line
  if [[ "$budget_exhausted" == true ]]; then
    append "$TRUNCATED_NOTE"
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((body_len + ${#line} + 1 > budget)); then
      budget_exhausted=true
      append ""
      append "$TRUNCATED_NOTE"
      return
    fi
    append "$line"
  done <"$1"
}

append_section() {
  append "### $1"
  append ""
  append_file "$2"
  append ""
}

{
  echo "New commits landed on the \`${UPSTREAM_BRANCH}\` branch of [${UPSTREAM_REPO}](https://github.com/${UPSTREAM_REPO})."
  echo "Triage each change and port what applies to the Swift app; see [${DOCS_PATH}](https://github.com/${GH_REPO}/blob/HEAD/${DOCS_PATH})."
  echo
  echo "- **Compare:** [\`${base:0:7}...${head:0:7}\`](${compare_url})"
  echo "- **Commits:** ${commit_count}"
  echo "- **Files changed:** ${file_count}"
  echo
  echo "### Triage checklist"
  echo
  echo "- [ ] Triage each change: port / not applicable / already covered"
  echo "- [ ] Link porting PRs here"
  echo "- [ ] Close when triaged and ported"
  echo
  echo "### Changed areas"
  echo
  cat "$tmp/areas.md"
  echo
} >"$tmp/header.md"

append_file "$tmp/header.md"
append_section "Commits" "$tmp/commits.md"
append_section "Referenced upstream pull requests" "$tmp/prs.md"
append_section "Changed files" "$tmp/files.md"
append "<!-- upstream-sync:base=${base} -->"
append "<!-- upstream-sync:head=${head} -->"

# --- Publish ----------------------------------------------------------------

if [[ "$DRY_RUN" == true ]]; then
  log "DRY_RUN: not creating an issue in $GH_REPO"
  echo "Title: $title"
  echo
  cat "$body"
  summary "## Dry run: $title" "" "$(cat "$body")"
  exit 0
fi

url="$(gh issue create --repo "$GH_REPO" --title "$title" --label "$SYNC_LABEL" --body-file "$body")"
echo "Created $url"

if [[ -n "$PROJECT_TOKEN" ]]; then
  if ! GH_TOKEN="$PROJECT_TOKEN" gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" >/dev/null; then
    echo "::warning::Could not add $url to project ${PROJECT_OWNER}/${PROJECT_NUMBER}"
  fi
fi

summary "Created [${title}](${url}) for ${commit_count} upstream commits ([compare](${compare_url}))."
