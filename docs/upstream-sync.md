# Upstream sync

This repository started from the full history of
[advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app), which
is still actively developed. The Swift app does not merge upstream code; it
**ports** upstream fixes and features by hand. A scheduled job reports new
upstream commits as GitHub issues labelled `upstream-port` so nothing is missed.

## How the daily job works

[`.github/workflows/upstream-sync.yml`](../.github/workflows/upstream-sync.yml) runs
daily (and on demand) and calls [`scripts/upstream-sync.sh`](../scripts/upstream-sync.sh),
which:

1. Finds the last reported upstream commit (see [markers](#state-markers)); if no
   issue has a marker yet, it uses `UPSTREAM_BASELINE`, the upstream commit this
   repository was forked from.
2. Fetches upstream `master` into the local ref `refs/upstream-sync/head`.
3. Exits quietly with "Upstream is up to date" when nothing is new.
4. Otherwise opens one issue titled
   `Upstream: port changes <base>..<head> (<N> commits)` containing:
   - a compare link and a triage checklist,
   - a table of changed areas,
   - the commits (linked to upstream, subjects sanitized so `#123` points at the
     upstream repo and `@mentions` do not ping anyone),
   - the upstream pull requests referenced by commit subjects,
   - the changed files grouped by area, with porting guidance.
5. Optionally adds the issue to the [roadmap project](https://github.com/users/djensenius/projects/15).

Long lists are truncated (`MAX_COMMITS`, `MAX_FILES`, and a 60,000-character
body cap); the compare link always has the full picture.

There is deliberately no mirror branch: the workflow's `GITHUB_TOKEN` cannot push
upstream commits that modify workflow files, so all state lives in issues.

### State markers

Each issue body ends with two hidden HTML comments:

```html
<!-- upstream-sync:base=<40-hex sha> -->
<!-- upstream-sync:head=<40-hex sha> -->
```

The next run reads the `head` marker from the most recently created
`upstream-port` issue (open **or** closed) and reports everything after it.
Consequences:

- Do not edit or delete the markers, and do not delete these issues. Closing
  them is fine.
- To skip ahead or re-report a range, create an `upstream-port` issue whose body
  contains the desired `head` marker (or edit the latest one).
- If the `upstream-port` label is renamed, update `SYNC_LABEL`.

## Triaging an `upstream-port` issue

1. Read the changed areas table, then walk the commits and referenced PRs.
2. For each change decide: **port**, **not applicable**, or **already covered**.
   Note the decision in a comment (or tick the PR checkbox) so the next person
   does not repeat the work.
3. Map upstream paths to the Swift app:

   | Upstream path | Swift app area |
   | --- | --- |
   | `ios/App/Shared/player/`, `ios/App/App/plugins/AbsAudioPlayer.swift` | Playback (AVFoundation, Now Playing, CarPlay) |
   | `ios/App/App/plugins/AbsDownloader.swift`, `ios/App/Shared/models/download/` | Downloads (background `URLSession`) |
   | `ios/App/Shared/util/ApiClient.swift`, `ios/App/Shared/models/server/` | Server API client and models |
   | `ios/App/Shared/util/Database.swift`, `ios/App/Shared/models/local/` | Local persistence (SwiftData) and progress sync |
   | `pages/`, `components/`, `layouts/` | SwiftUI screens and views |
   | `store/`, `plugins/`, `mixins/`, `utils/`, `objects/`, `middleware/` | App state, services, and helpers |
   | `assets/`, `static/` | Asset catalog (only if the asset is still used) |
   | `strings/*.json` | String Catalog — re-import translations |
   | `android/` | Usually not applicable; check whether a server/API fix also affects us |
   | `.github/`, `fastlane/`, Node/Capacitor config | Not applicable |

   Exact Swift module paths will be listed in [`AGENTS.md`](../AGENTS.md) once the
   Phase 0 app structure lands.
4. Open one porting PR per issue-sized change, reference the upstream commit or PR
   (for example `Ports advplyr/audiobookshelf-app#2002`), and link the PR in the
   `upstream-port` issue.
5. Close the issue once every change is triaged and the ports are merged.

## Running it manually

On GitHub (prints the issue to the job summary without creating it):

```sh
gh workflow run upstream-sync.yml -f dry_run=true
```

Drop `-f dry_run=true` (or pass `-f dry_run=false`) to create the issue
immediately instead of waiting for the schedule.

Locally (always a dry run; needs `gh` authenticated):

```sh
mise run upstream:check
```

`GH_REPO` defaults to the current repository, but `gh` may resolve to upstream when
an `upstream` remote exists; the script refuses to run against the upstream repo,
so set it explicitly if needed:

```sh
GH_REPO=djensenius/audiobookshelf-apple mise run upstream:check
```

### Configuration

All settings are environment variables with defaults in the script:

| Variable | Default | Purpose |
| --- | --- | --- |
| `UPSTREAM_REPO` | `advplyr/audiobookshelf-app` | Repository to follow |
| `UPSTREAM_BRANCH` | `master` | Branch to follow |
| `UPSTREAM_BASELINE` | `609f9d6…` | Starting point when no marker exists |
| `SYNC_LABEL` | `upstream-port` | Label for created and scanned issues |
| `GH_REPO` | current repository | Where issues are created |
| `PROJECT_OWNER` / `PROJECT_NUMBER` | `djensenius` / `15` | Project to add issues to |
| `PROJECT_TOKEN` | empty | Token for adding issues to the project |
| `DRY_RUN` | `false` | `true` prints instead of creating |
| `MAX_COMMITS` / `MAX_FILES` | `150` / `300` | List truncation limits |

## Adding issues to the project

`GITHUB_TOKEN` cannot write to user-owned Projects. Pick one:

- **Built-in automation (no secret):** in the project's *Workflows* settings,
  enable *Auto-add to project* for this repository with the filter
  `is:issue label:upstream-port`.
- **Repository secret:** add `UPSTREAM_SYNC_PROJECT_TOKEN` containing a classic
  PAT with the `project` scope, or a fine-grained token with *Projects:
  read and write* access. The script then runs `gh project item-add` and only
  warns if that fails.

## If upstream rewrites history

The job fails with `Upstream history was rewritten` when the last reported commit
is no longer an ancestor of upstream `master` (force-push), or with
`Base commit … is not available locally` when it no longer exists. To recover:

1. Compare the old and new upstream histories and find the first upstream commit
   that has not been reported yet (its parent is the new base).
2. Create an `upstream-port` issue (it can be closed immediately) whose body
   contains `<!-- upstream-sync:head=<new base sha> -->`, explaining the reset.
3. Re-run the workflow with `dry_run=true` to confirm, then without it.

If the old range had unported changes, keep its issue open until they are triaged.
