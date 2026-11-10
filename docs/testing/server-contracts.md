# Server contract tests

`ABSServerContractTests` (in `Packages/AudiobookshelfKit`) runs the production API, auth and
progress code against a real Audiobookshelf server, so decoding and sync rules are checked
beyond hand-written fixtures. Run it before changing the client, token refresh, progress sync or
downloads, and when the supported server range changes ([ADR 0007](../adr/0007-streaming.md)).

The suite is opt-in. Without `ABS_TEST_SERVER_URL`, `mise run test:kit` compiles it and
reports every test as skipped, with a message that points here.

## Run it

```sh
mise run test:server                              # server 2.26.0, the minimum, in Docker
ABS_SERVER_VERSION=2.37.2 mise run test:server    # another release
mise run server:run                               # keep a seeded server for manual use
scripts/test-server.sh test --filter ProgressContractTests   # swift test arguments replace the default filter
```

You need Docker (OrbStack or Docker Desktop), `ffmpeg` (`brew install ffmpeg`) and Xcode. A run
takes about 20 seconds once the server image is pulled and the package is built.

| Variable | Meaning |
| --- | --- |
| `ABS_SERVER_VERSION` | Release to run. Default `2.26.0`. |
| `ABS_SERVER_BACKEND` | `docker` (default), or `node`: a source checkout run with Node 20, for machines without Docker. Run it as `ABS_SERVER_BACKEND=node mise exec node@20 -- scripts/test-server.sh test`. |
| `ABS_SERVER_TIMEOUT` | Seconds to wait for startup and for the first scan. Default `120`. |

The script generates the media in a temporary directory with a random root password, starts
`ghcr.io/advplyr/audiobookshelf:<version>` on a free port of 127.0.0.1, creates the root user
(`POST /init`) and the two libraries, scans, waits for the items, exports `ABS_TEST_SERVER_URL`,
`ABS_TEST_USERNAME`, `ABS_TEST_PASSWORD` and `ABS_TEST_SERVER_VERSION`, and runs
`swift test --filter ABSServerContractTests`. The server runs with `RATE_LIMIT_AUTH_MAX=0`: its
default of 40 sign-ins and refreshes per 10 minutes would end the suite with 429 responses.
`server:run` stops after the scan, prints the URL, user name and password to the terminal and
keeps the server until Ctrl-C. Nothing is written to a file.

To use a server you started yourself, set the three `ABS_TEST_*` variables and run
`swift test --package-path Packages/AudiobookshelfKit --filter ABSServerContractTests`. It needs
the seeded libraries below and a root user, and the tests create and delete users and write
progress and sessions, so use a scratch server.

## What is seeded

Generated sine tones only; nothing is recorded or copyrighted. Books: *The Synthetic Tale* by Ada
Fixture (two MP3 files of 30 s and 20 s with ID3 tags) and *Single File Tale* (one 40 s M4B with
chapters Opening, Middle and Ending). Podcasts: *Synthetic Cast* with one 20 s MP3 episode.

## Contracts

| Suite | What it pins |
| --- | --- |
| `AuthContractTests` | Status, ping and validation; password login and its JWT pair; `/api/authorize`; a wrong password |
| `TokenRefreshContractTests` | Refresh and rotation, the old refresh token, concurrent refreshes, refresh before expiry, logout |
| `LibraryContractTests` | Libraries, minified and expanded books and podcasts, chapters, audio files, tracks, shelves, search, authors, series |
| `CollectionWriteContractTests` | Five collection writes; ordered two-book lifecycle and empty reads; permissions, atomic invalid create, no-ops/errors, version differences and failure teardown |
| `PlaybackSessionContractTests` | Start, sync and close; resume; same-device takeover; track URLs and ranges; downloads; local session upload |
| `ProgressContractTests` | Each progress group, `lastUpdate`, finished and auto-finish, ebook progress, batch update, delete |
| `LocalProgressContractTests` | `LocalProgressStore` sending to the server and settling on what it holds |

Not covered yet: bookmarks, playlists, listening stats, Socket.IO events
(`ABSRealtime`) and OpenID sign-in (see [oidc.md](oidc.md) for the manual check).

## Differences between versions

The suite asserts these per version. Other versions check only what holds for all.

| | 2.26.0 | 2.37.2 |
| --- | --- | --- |
| Access / refresh token lifetime | 12 h / 7 d | 1 h / 30 d |
| Token id (`jti`) | none: two tokens for one user in the same second are identical | present |
| Refresh token replaced by a refresh | rejected at once | accepted for 10 minutes, with the current refresh token returned |
| `DELETE /api/me/progress/:id` twice | 200 | 404 |
| MP3 duration of a 30 s file | about 30.1 s (encoder padding) | 30 s |

Behaviour that holds on both, and that fixtures did not capture:

- `POST /login` returns the refresh token only in a cookie unless `x-return-tokens: true` is sent.
  `POST /logout` revokes the cookie's refresh token before the `x-refresh-token` header's.
- `POST /api/items/:id/play` closes the user's other sessions on the same `deviceId`, even for
  another item. A different device is left open.
- A session sync's `timeListened` is a delta. An update that leaves less than 10 s finishes the
  item, but the PATCH that creates the row never does.
- `isFinished` in a PATCH makes the server ignore `progress`; `isFinished: false` on a finished
  item resets `currentTime` and `progress` to 0.
- An ebook-only PATCH on a new row creates `duration` 0 and `currentTime` 0, and a location
  without `ebookProgress` keeps the stored `ebookProgress`.
- An uploaded local session older than the stored progress is kept, with `progressSynced` false.

## Add a contract

Add a test to the suite for its area, or a file under `Tests/ABSServerContractTests` whose suite
has `.requiresServer, .tags(.serverContract)`. Use production types only (`APIClient`, the
endpoint wrappers, `LocalProgressStore`) and wrap the test in
`try await ContractServer.require().withUser { session in … }`: it creates a user and deletes it
afterwards, so tests share no progress, sessions or tokens. Find the seeded items with
`ContractSeed.shared.data()`. Compare durations with `approximately` (±0.5 s), and branch on
`ContractServer.current?.version` only for a difference listed above. Run `mise run test:server`
on 2.26.0 and 2.37.2.

## Cleanup

Collection writes use `CollectionContractFixture`, not the shared `withUser` harness:
collections are library-wide, have no owner and **survive user deletion**. Each fixture creates
unique ordinary-type users through the standard admin endpoint, explicitly granting
`permissions.update/delete = true` for writers. Separate default users verify all five 403s
on an actual collection. Restricted-library users are also local to this fixture; root permissions,
shared user provisioning and the two seeded books are never changed.

The fixture registers exact created collection IDs immediately from the successful response,
before expanded-book decoding, and deletes those IDs **before** its users on both success and
failure. Cleanup attempts every resource; failures surface without replacing the primary error.
A test deliberately throws inside the body, then checks every registered collection/user ID is
404. Never delete by name/prefix, rely on global collection counts, or assume deleting a user
removes collections. Only run mutations against disposable servers you own. Prefer a worktree-local
`TMPDIR=$PWD/.build/server-tmp` (create it first); retain captures/helpers only under that worktree's
`.build` or owned session artifacts.

The script's trap removes the container and `${TMPDIR}/abs-contract.*` on success, failure,
Ctrl-C and SIGTERM. A SIGKILL cannot be trapped; remove strays with:

```sh
docker rm -f $(docker ps -aq --filter label=abs-contract-test=1)
rm -rf "${TMPDIR:-/tmp}"/abs-contract.*
```

The broad commands above are only appropriate when **all** matched resources are yours. On a
shared host, record the exact container name and temporary directory printed/created by your run,
then remove only those resources. Never clean another contributor's containers, caches or worktrees.

## Collection write contract and capture provenance

| Factory | Request | Success |
| --- | --- | --- |
| `CollectionEndpoints.create` | `POST /api/collections`: `name`, `libraryId`, nonempty `books`, optional `description` | 200 flat expanded `LibraryCollection` |
| `update` | `PATCH /api/collections/:id`: optional `name`, `description`, `books` | 200 expanded collection, including no-op |
| `delete` | `DELETE /api/collections/:id`, no body | 200 plain `OK` (`EmptyResponse`) |
| `addBooks` | `POST /api/collections/:id/batch/add`: `{books: [...]}` | 200 expanded collection |
| `removeBooks` | `POST /api/collections/:id/batch/remove`: `{books: [...]}` | 200 expanded collection |

Every book ID is a **library-item ID**, not a media ID. Create rejects invalid, wrong-library,
non-book and duplicate IDs atomically with 400. Update nil fields are omitted; `description: ""`
clears. `bookIDsInOrder` encodes as `books` and is a **full permutation of existing membership**,
not replacement membership; omitted/empty books are no-ops. Add partially accepts valid IDs,
ignores existing members, returns 400 for zero valid IDs, and appends in database order rather
than promising request order. Remove ignores unknown/nonmember IDs but returns 500 for an empty
array. Empty collections return 200 `books: []`, including detail GET; a nonempty collection
with all books filtered from a user instead returns 404 (not the owned two-book seed scenario).

2.37.2 strips tags from names, rejects inaccessible-library create with 403 and hides inaccessible
IDs with 404. 2.26.0 lacks these library-access checks and name sanitization. Tests preserve these
differences and avoid exotic invalid JSON types. Unknown collection lookup precedes write permission
checks. All writes except delete need update permission; delete needs delete permission.

Canonical source is `advplyr/audiobookshelf`, with immutable evidence:

- 2.26.0 pin `264ae928a9c1af620487488110eec816b14e23ec`:
  [routes](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/routers/ApiRouter.js#L144-L154),
  [writes](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/CollectionController.js#L31-L212),
  [batch/middleware](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/CollectionController.js#L307-L441),
  [serialization](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/models/Collection.js#L222-L289),
  [user deletion](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/UserController.js#L365-L407).
- 2.37.2 pin `edb1f7efc92ecacdef51aafb4d9d5054ce10604f`:
  [routes](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/routers/ApiRouter.js#L144-L154),
  [writes](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/CollectionController.js#L32-L223),
  [batch/middleware](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/CollectionController.js#L318-L456),
  [serialization](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/Collection.js#L222-L289),
  [user deletion](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/UserController.js#L363-L406),
  [permission provisioning](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/UserController.js#L152-L168),
  [ordinary defaults](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/User.js#L169-L184).

The two `ABSAPITests/Fixtures/collection-writes-*.json` fixtures were captured on 2026-11-10
from one actual create per owned disposable official image, using the existing ordered
`taleID/singleFileID` seed. No mutation was replayed just to capture JSON. Collection IDs,
book/media/author IDs, paths and dates are synthetic; filesystem/audio-probe fields are trimmed.
Both raw responses had exactly two expanded library items in request order. Tests compare raw
versus decoded counts/IDs, and live writes compare the untrimmed response before trusting lossy
decoding. Capture collections were explicitly deleted and the servers/temp directories removed.

| Official image | RepoDigest (`ghcr.io/advplyr/audiobookshelf@…`) | `/status.serverVersion` | Revision label |
| --- | --- | --- | --- |
| `:2.26.0` | `sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5` | `2.26.0` | `264ae928a9c1af620487488110eec816b14e23ec` |
| `:2.37.2` | `sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa` | `2.37.2` | `edb1f7efc92ecacdef51aafb4d9d5054ce10604f` |

`Config.Labels` also reported `org.opencontainers.image.source=https://github.com/advplyr/audiobookshelf`,
`title=audiobookshelf`, `url=https://github.com/advplyr/audiobookshelf`, `licenses=GPL-3.0`,
`description=Self-hosted audiobook and podcast server`; `version` matched each release, and `created`
was respectively `2025-07-12T19:13:12.866Z` / `2026-10-23T19:58:49.792Z`.
Before any new acceptance run, inspect official image digests, actual server version and **all**
labels. Require a present revision label matching the exact pin. A mismatch fails the gate;
an absent label is not proof: pause for a coordinator decision on a separately recorded
exact-source disposable build fallback. A tag or version string alone is insufficient.

Run the focused `Collection|LibraryEndpointsTests|ItemEndpointsTests|LibraryResponseDecodingTests|LibraryModelTests`
package filter, then `scripts/test-server.sh test --filter CollectionWriteContractTests` and
`mise run test:server` with each exact `ABS_SERVER_VERSION=2.26.0` and `2.37.2`. Record actual
non-skipped live test counts and cleanup, not default-suite skips. Also run `mise run lint`,
`mise run xcproj:check` and `mise run test`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
and `MISE_TRUSTED_CONFIG_PATHS=$PWD`. These checks do not constitute VM, UI or device acceptance.

## CI

`.github/workflows/server-contract.yml` runs on `workflow_dispatch` (optionally with one
version) and every night, for 2.26.0 and 2.37.2. A failure fails the job.

GitHub's macOS runners have no Docker, and `ABSCore`, `ABSAPI` and `ABSData` use Apple
frameworks (Security, SwiftData), so a Linux runner cannot build the suite. The job runs on the
macOS `xcode-27` runner with `ABS_SERVER_BACKEND=node`: Node 20 from mise, ffmpeg from Homebrew
and the server's source release from GitHub.

Checked on a developer Mac: ShellCheck, actionlint, the Docker backend and the node backend (Node
20.20.2) on both versions. Only a hosted run shows that the runner has network access for
`brew install ffmpeg`, the Node download and the sqlite3 binary, how long the job takes, and
that the schedule fires.

## Troubleshooting

- **Every test is skipped.** `ABS_TEST_SERVER_URL` is not set; use `mise run test:server`.
- **Docker is not running, or the pull fails.** Start OrbStack or Docker Desktop and check that
  `docker pull ghcr.io/advplyr/audiobookshelf:2.26.0` works.
- **"timed out … scan found 0 of 2 items".** The server could not read the media; the script
  prints its last log lines. On a slow machine, raise `ABS_SERVER_TIMEOUT`.
- **429 from `/login` or `/auth/refresh`.** Only on a server you started yourself: start it with
  `RATE_LIMIT_AUTH_MAX=0`.
- **A new local session counts as stale.** The server compares the session's `updatedAt` with
  its own clock, so keep the host and server clocks close.
