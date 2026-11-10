#!/usr/bin/env bash
# Report new upstream (advplyr/audiobookshelf-app) commits as a GitHub issue.
#
# State lives in issue markers, not a mirror branch: the newest issue labelled
# $SYNC_LABEL whose body contains `<!-- upstream-sync:head=<sha> -->` records the
# last upstream commit that was reported. Only issues opened by trusted authors
# (GitHub Actions, the repository owner, $UPSTREAM_SYNC_TRUSTED_AUTHORS) count.
# See docs/upstream-sync.md.
set -euo pipefail

# Byte-wise, locale-independent text handling (sed, awk, sort, and bash patterns
# such as [[:cntrl:]], which would otherwise match U+200B in some UTF-8 locales).
export LC_ALL=C

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
UPSTREAM_SYNC_TRUSTED_AUTHORS="${UPSTREAM_SYNC_TRUSTED_AUTHORS:-}"
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

# Normalize an issue author login: lowercase, and map gh's "app/<name>" form to
# the REST "<name>[bot]" form (e.g. app/github-actions -> github-actions[bot]).
normalize_author() {
  local login
  login="$(lower "$1")"
  if [[ "$login" == app/* ]]; then
    login="${login#app/}[bot]"
  fi
  printf '%s' "$login"
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

# Authors whose issues may carry upstream-sync markers. Anyone can open an issue,
# so marker issues from other authors are ignored rather than trusted (or fatal).
trusted_authors="github-actions[bot],$(normalize_author "${GH_REPO%%/*}")"
IFS=',' read -r -a extra_authors <<<"$UPSTREAM_SYNC_TRUSTED_AUTHORS"
for author in ${extra_authors[@]+"${extra_authors[@]}"}; do
  author="${author//[[:space:]]/}"
  [[ -n "$author" ]] || continue
  author="$(normalize_author "$author")"
  [[ "$author" =~ ^[a-z0-9-]+(\[bot\])?$ ]] ||
    die "UPSTREAM_SYNC_TRUSTED_AUTHORS must be a comma-separated list of GitHub logins (got '$author')"
  trusted_authors+=",$author"
done
export TRUSTED_AUTHORS="$trusted_authors"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- Determine the range ----------------------------------------------------

# List issues whose body mentions "upstream-sync:head=" as TSV lines:
#   createdAt, number, labelled with $SYNC_LABEL (1/0), last valid head marker or "-",
#   opened by a trusted author (1/0), normalized author login.
marker_jq() {
  # shellcheck disable=SC2016 # $trusted and $author are jq variables, not shell ones.
  printf '%s' 'def norm: ascii_downcase | if startswith("app/") then .[4:] + "[bot]" else . end;
    (env.TRUSTED_AUTHORS | split(",")) as $trusted
    | .[] | select((.body // "") | contains("upstream-sync:head="))
    | ((.author.login // "") | norm) as $author
    | [.createdAt, (.number | tostring), '"$1"',
       (([(.body // "") | match("<!-- upstream-sync:head=([0-9a-f]{40}) -->"; "g")] | last | .captures[0].string) // "-"),
       (if $author != "" and any($trusted[]; . == $author) then "1" else "0" end), $author]
    | @tsv'
}

# Recent labelled issues (not subject to search-index lag) ...
gh issue list --repo "$GH_REPO" --label "$SYNC_LABEL" --state all --limit 100 \
  --json number,body,createdAt,author --jq "$(marker_jq '"1"')" >"$tmp/markers.raw"
# ... plus any issue with a marker, labelled or not.
SYNC_LABEL="$SYNC_LABEL" gh issue list --repo "$GH_REPO" --state all --limit 100 \
  --search '"upstream-sync:head=" in:body sort:created-desc' --json number,body,createdAt,labels,author \
  --jq "$(marker_jq '(if any(.labels[]?; .name == env.SYNC_LABEL) then "1" else "0" end)')" >>"$tmp/markers.raw"

# Newest first, one line per issue, ignoring issues from untrusted authors. The
# newest labelled issue mentioning a marker, or the newest issue with a valid
# marker if that is newer, decides the base.
sort -r "$tmp/markers.raw" | awk -F '\t' '!seen[$2]++' >"$tmp/markers"
while IFS=$'\t' read -r _ issue _ _ trusted author; do
  if [[ "$trusted" != 1 ]]; then
    log "Ignoring $GH_REPO#$issue: it mentions upstream-sync:head= but its author (${author:-unknown}) is not trusted (see $DOCS_PATH)"
  fi
done <"$tmp/markers"
latest_marker="$(awk -F '\t' '$5 == "1" && ($3 == "1" || $4 != "-") { print; exit }' "$tmp/markers")"

if [[ -z "$latest_marker" ]]; then
  base="$UPSTREAM_BASELINE"
  log "No issue with an upstream-sync marker found; using baseline $base"
else
  IFS=$'\t' read -r _ marker_issue marker_labelled base _ <<<"$latest_marker"
  if [[ "$marker_labelled" != 1 ]]; then
    die "Issue $GH_REPO#$marker_issue has the newest upstream-sync marker but is not labelled $SYNC_LABEL; re-apply the label or set SYNC_LABEL (see $DOCS_PATH)"
  fi
  if ! [[ "$base" =~ $SHA_RE ]]; then
    die "Issue $GH_REPO#$marker_issue mentions upstream-sync:head= but has no valid <!-- upstream-sync:head=<40-hex sha> --> marker; fix it (see $DOCS_PATH)"
  fi
  log "Last synced upstream head: $base (from $GH_REPO#$marker_issue)"
fi

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
# Links via redirect.github.com (like Dependabot) do not create cross-reference
# backlinks on upstream issues and pull requests.
REF_URL="https://redirect.github.com/${UPSTREAM_REPO}/issues"

git -c log.showSignature=false log --no-color --no-use-mailmap --encoding=UTF-8 \
  --reverse --date=short --format="%H${US}%s${US}%an${US}%ad" "${base}..${head}" >"$tmp/log.raw"

# Sanitize text that ends up in the issue:
# - escape & first so entities like &#64; / &#35; cannot smuggle in @ or #,
#   then neutralize HTML and escape table pipes;
# - send github.com links through redirect.github.com (scheme and host matched
#   case-insensitively; bracket classes because BSD sed has no I flag);
# - break owner/repo#123 references with a zero-width space, and turn bare
#   #123 / GH-123 into upstream links whose text is not auto-referenced;
# - break @mentions with a zero-width space so upstream users are not pinged.
sed -E \
  -e 's/&/\&amp;/g' \
  -e 's/</\&lt;/g' \
  -e 's/>/\&gt;/g' \
  -e 's/[|]/\\|/g' \
  -e 's~[Hh][Tt][Tt][Pp]([Ss])?://([Ww][Ww][Ww]\.)?[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm]/~https://redirect.github.com/~g' \
  -e "s~([[:alnum:]_/])#([0-9])~\\1#${ZWSP}\\2~g" \
  -e "s~(^|[^[:alnum:]_/])#([0-9]+)~\\1[${UPSTREAM_REPO}#\\2](${REF_URL}/\\2)~g" \
  -e "s~(^|[^[:alnum:]_])GH-([0-9]+)~\\1[${UPSTREAM_REPO}#\\2](${REF_URL}/\\2)~g" \
  -e "s/@/@${ZWSP}/g" \
  "$tmp/log.raw" >"$tmp/log"

{
  echo "| Commit | Subject | Author | Date |"
  echo "| --- | --- | --- | --- |"
  shown=0
  while IFS="$US" read -r sha subject author date; do
    subject="${subject//[[:cntrl:]]/ }"
    author="${author//[[:cntrl:]]/ }"
    if ((shown >= MAX_COMMITS)); then
      echo
      echo "_Showing the first ${MAX_COMMITS} of ${commit_count} commits; see the [full comparison](${compare_url})._"
      break
    fi
    echo "| [\`${sha:0:7}\`](https://github.com/${UPSTREAM_REPO}/commit/${sha}) | ${subject} | ${author} | ${date} |"
    shown=$((shown + 1))
  done <"$tmp/log"
} >"$tmp/commits.md"

# --- Referenced upstream issues and pull requests ---------------------------

# The same reference forms the sanitizer recognizes: bare #123 and GH-123, plus
# owner/repo#123 for the upstream repository (owner/repo case-insensitive).
cut -d "$US" -f 2 "$tmp/log.raw" >"$tmp/subjects"
upstream_ref_re="$(lower "$UPSTREAM_REPO")"
upstream_ref_re="${upstream_ref_re//./\\.}"
{
  grep -oE '(^|[^[:alnum:]_/])#[0-9]+' "$tmp/subjects" || true
  grep -oE '(^|[^[:alnum:]_])GH-[0-9]+' "$tmp/subjects" || true
  tr '[:upper:]' '[:lower:]' <"$tmp/subjects" |
    { grep -oE "(^|[^[:alnum:]_./-])${upstream_ref_re}#[0-9]+" || true; }
} |
  { grep -oE '[0-9]+$' || true; } |
  awk '{ n = $0 + 0; if (n > 0) print n }' |
  sort -n -u >"$tmp/prs"

if [[ -s "$tmp/prs" ]]; then
  while IFS= read -r pr; do
    echo "- [ ] [${UPSTREAM_REPO}#${pr}](${REF_URL}/${pr})"
  done <"$tmp/prs" >"$tmp/prs.md"
else
  echo "_No issues or pull requests referenced in commit subjects._" >"$tmp/prs.md"
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

# Wrap a path or status in a Markdown code span (backticks become quotes and
# control characters such as newlines become "?", so paths cannot inject Markdown).
code() {
  local bt='`' q="'" s="${1//[[:cntrl:]]/?}"
  printf '%s%s%s' "$bt" "${s//"$bt"/"$q"}" "$bt"
}

file_count=0
git diff --no-color --no-ext-diff --no-relative --find-renames -O/dev/null --name-status -z \
  "$base" "$head" >"$tmp/diff"
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
append_section "Referenced upstream issues and pull requests" "$tmp/prs.md"
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
