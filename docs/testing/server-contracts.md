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
scripts/test-server.sh test --search-contract                # only isolated owned search, not ordinary suites
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
two sequential Swift test processes: `--filter ABSServerContractTests --skip SearchContractTests`,
then an explicitly owned `--filter SearchContractTests` pass. Either failure fails the harness.
Focused Swift arguments retain their existing behavior and do not add another pass.
The server runs with `RATE_LIMIT_AUTH_MAX=0`: its
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
| `RecentEpisodesContractTests` | Read-only normal/empty pages and book-library 404; strict raw counts, identities, podcast and audio expansions |
| `SearchContractTests` | Separately gated owned libraries; all seven search groups plus genres, strict nested media, limits/errors, exact-ID cascade and failure cleanup |
| `CollectionWriteContractTests` | Five collection writes; ordered two-book lifecycle and empty reads; permissions, atomic invalid create, no-ops/errors, version differences and failure teardown |
| `PlaylistWriteContractTests` | Five owner-only writes; book/episode lifecycles, strict raw membership checks, ownership/access denials, atomic invalid add, safe characterization and exact-ID failure teardown |
| `PlaybackSessionContractTests` | Start, sync and close; resume; same-device takeover; track URLs and ranges; downloads; local session upload |
| `ProgressContractTests` | Each progress group, `lastUpdate`, finished and auto-finish, ebook progress, batch update, delete |
| `LocalProgressContractTests` | `LocalProgressStore` sending to the server and settling on what it holds |

Not covered yet: bookmarks, listening stats, Socket.IO events
(`ABSRealtime`) and OpenID sign-in (see [oidc.md](oidc.md) for the manual check).

See [owned search contracts](search-contracts.md) for the explicit mode, fail-closed ownership,
Docker/node provenance, disjoint media, capture format and reproduction commands. Default full
runs require one of the two reviewed pins; other releases remain usable with focused ordinary
Swift selectors. Search skips in ad-hoc/package runs are **not** live search evidence.

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

The script's trap bounds and verifies shutdown of its exact owned server on success, failure,
Ctrl-C and SIGTERM, then removes its temporary directory. Unverified containment retains the data
and fails an otherwise successful run; an existing primary failure code is preserved. See the
[cleanup regressions](search-contracts.md#provenance-captures-and-cleanup). A SIGKILL cannot be trapped; remove strays with:

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

## Playlist write contract and captures

| Factory | Request | Success |
| --- | --- | --- |
| `PlaylistEndpoints.create` | `POST /api/playlists`: `name`, `libraryId`, `items`, optional `description` | 200 expanded `Playlist` |
| `update` | `PATCH /api/playlists/:id`: optional `name`, `description`, `items` | 200 expanded playlist, including no-ops |
| `delete` | `DELETE /api/playlists/:id`, no body | 200 plain `OK` (`EmptyResponse`) |
| `addItems` | `POST /api/playlists/:id/batch/add`: `{items: [...]}` | 200 expanded playlist |
| `removeItems` | `POST /api/playlists/:id/batch/remove`: `{items: [...]}` | 200 expanded playlist, even when removing the last member |

Playlists are **user-owned**, unlike collections. Ordinary owners need no update/delete permission.
Every ID route, including GET, returns 403 to a second ordinary user **and administrators**.
Unknown IDs return 404. Removing the last member deletes the playlist: the mutation returns 200
with `items: []`, then GET returns 404. Empty add/remove batches return 400.

`PlaylistItemReference` uses `libraryItemId` for a book and both `libraryItemId` and the correct
`episodeId` for a podcast episode. Requests are plain `Encodable & Sendable`; nil is omitted.
Callers must enforce valid kind, known references, same-library membership, uniqueness and a full
reorder permutation using metadata. `itemsInOrder` encodes as `items`: it reorders membership,
never replaces it. Nil/empty lists leave order unchanged. Empty name/description strings are
ignored, not clearing operations. Length-mismatched and unknown-library-item reorders return 400.
Adding an unknown library-item ID rejects the **whole batch**, even alongside a valid new book;
existing members are no-ops. Removing unknown/nonmembers is a no-op.

Both pins passed the ordinary-owner two-book lifecycle: full reorder, text no-op/persistence,
tail removal and re-add in order, remove-all/GET 404 and explicit delete. One podcast episode
passed create, re-add no-op and remove-last/GET 404. Head removal followed by append can leave
order-number ties, so that case asserts membership, not invented ordering.

Observed safe characterization on **both** 2.26.0 and 2.37.2:

- Empty and omitted create items return 200 empty playlists; subsequent owner GET is also 200.
  This differs from removing the last member of an existing playlist.
- Duplicate **book create** retains two entries, including on GET. This is characterization,
  not a recommended request policy; callers should supply unique references.
- A list primed before create is fresh immediately after create, metadata update, batch remove,
  batch add and explicit delete. No sleeps, cache-busting parameters or mutation replay were used.
- 2.37.2 strips name tags, denies restricted-library create with 403, and returns 404 on all owner
  ID routes after that owner's library access is removed. 2.26.0 preserves tags and permits these
  operations. Neither version's non-owner restriction is bypassed by admin privileges.

**Source-only hazards, deliberately not live-tested:** podcast batch adds without episode IDs,
bogus episode IDs on books, mixed/cross-library adds, duplicate entries within one add, and
nonmember reorders. The server does not safely validate all combinations and can leave dangling
rows or fail asynchronously. Duplicate episode create rejection is source-derived, not exercised.
The one-episode seed cannot establish multi-episode order or mismatched-episode identity behavior.
No single-item, create-from-collection or deprecated global list route is added or exercised.

Immutable canonical source evidence (not inferred from a version string):

| Contract | 2.26.0 (`264ae928a9c1af620487488110eec816b14e23ec`) | 2.37.2 (`edb1f7efc92ecacdef51aafb4d9d5054ce10604f`) |
| --- | --- | --- |
| Routes | [157–168](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/routers/ApiRouter.js#L157-L168) | [157–168](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/routers/ApiRouter.js#L157-L168) |
| Create | [28–119](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/PlaylistController.js#L28-L119) | [29–125](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/PlaylistController.js#L29-L125) |
| Update/delete | [159–261](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/PlaylistController.js#L159-L261) | [166–272](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/PlaylistController.js#L166-L272) |
| Batch membership | [383–491](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/PlaylistController.js#L383-L491) | [394–502](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/PlaylistController.js#L394-L502) |
| Ownership/access | [560–574](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/PlaylistController.js#L560-L574) | [575–593](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/PlaylistController.js#L575-L593) |
| Serialization | [335–376](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/models/Playlist.js#L335-L376) | [335–376](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/Playlist.js#L335-L376) |
| User-delete cascade | [365–407](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/UserController.js#L365-L407) | [363–406](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/UserController.js#L363-L406) |
| Library list | [855–872](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/LibraryController.js#L855-L872) | [853–870](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/LibraryController.js#L853-L870) |

### Playlist ownership and reproduction

`PlaylistContractFixture` creates unique ordinary users, registers every playlist's exact ID from
the raw successful response **before decoding**, then attempts deletion through its owner session.
404 is acceptable after auto-deletion or loss of library access. It then admin-deletes its users
and verifies **every registered playlist and user ID** is 404. Admin GET 403 is a cleanup failure,
not evidence of absence. User deletion's playlist cascade is explicitly live-tested and is the
fallback for inaccessible playlists. A deliberate body failure verifies teardown and preservation
of the primary error; cleanup errors are separately surfaced. No root permissions, shared fixture,
seed, real server, broad name/count cleanup or collection implementation is changed.

Captured on 2026-11-10, independently for each supported pin: genuine two-book and one-episode
creates plus their library-list responses. All `Config.Labels`, RepoDigests and actual `/status`
versions were rechecked; they match the complete official-image provenance table and label values
above. Both revision labels are present and match the exact pins. An absent label still requires
separate recorded exact-source fallback authorization; a mismatching label fails.

`ABSAPITests/Fixtures/playlist-writes-*.json` contains representative sanitized responses:
stable synthetic IDs/dates, trimmed filesystem/probe metadata, retained member order and episode
track shape. Untrimmed raw responses were checked for two books/one episode and ordered
`(libraryItemId, episodeId)` pairs, then decoded with **strict** `LibraryItem`/`PodcastEpisode`
checks before accepting fixtures. Optional expansion leniency cannot hide a valid nested decode
failure. `Playlist.items` alone is element-lossy; required identities still fail/drop. Outer
`PagedResults.rawCount` counts playlists, not members; tests inspect raw nested counts independently.
Existing reads, realtime `playlist_added`, initializers and encoding remain compatible.

Run from the owned worktree, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
`MISE_TRUSTED_CONFIG_PATHS=$PWD`, and `TMPDIR=$PWD/.build/server-tmp` (create it first):

```sh
swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm \
  --filter 'Playlist|LibraryEndpointsTests|ItemEndpointsTests|LibraryResponseDecodingTests|LibraryModelTests|RealtimeEventTests'
ABS_SERVER_VERSION=2.26.0 scripts/test-server.sh test --filter PlaylistWriteContractTests
ABS_SERVER_VERSION=2.37.2 scripts/test-server.sh test --filter PlaylistWriteContractTests
ABS_SERVER_VERSION=2.26.0 mise run test:server
ABS_SERVER_VERSION=2.37.2 mise run test:server
mise run lint
mise run xcproj:check
mise run test
git diff --check
```

Set `ABS_PLAYLIST_LIVE_CAPTURE_DIR=$PWD/.build/playlist-live/<version>-<run>` for live runs to retain
the actual successful mutation/detail/list responses and exact-ID cleanup results in per-fixture
UUID directories. Each response is captured once; no write is replayed for capture. The initial
untrimmed captures live at `.build/playlist-captures/{2.26.0,2.37.2}/`, with `book-create.json`,
`podcast-create.json`, `book-list.json`, `podcast-list.json`, `identities.json`, `provenance.json`,
`ledger.json` and `cleanup.json`. These are local synthetic artifacts, not bundled resources.
Recheck those captures, their lists and strict nested decoding with:

```sh
ABS_PLAYLIST_CAPTURE_DIR=$PWD/.build/playlist-captures \
  swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm --filter PlaylistResponseTests
```

Both focused live runs executed all 10 playlist tests without skips. The full-server suite's existing
unrelated series-fixture skip does not imply a playlist skip. Default package-suite server skips are
not live evidence. These checks do not claim UI, device, playback or full parent-issue acceptance.

## Recent episodes: wire counts and authentic captures

`LibraryEndpoints.recentEpisodes` still sends authenticated
`GET /api/libraries/:id/recent-episodes?limit=50&page=0` by default.
`RecentEpisodesPage.rawCount` counts **wire rows**, not successfully decoded episodes:
it uses the raw unkeyed container count, falling back to decoded count like `PagedResults`.
The trailing optional initializer argument defaults to `episodes.count`. There is no `total`,
query clamping, new endpoint or UI paging algorithm. Missing/null episode lists, number/string
paging leniency and malformed optional podcast tolerance are unchanged.

Both official images were independently inspected and captured on 2026-11-10, **before**
fixture/decoder edits. All image labels and RepoDigests matched the provenance table above:

| Version / actual `/status.serverVersion` | Revision label | RepoDigest (`sha256:`) |
| --- | --- | --- |
| `2.26.0` | `264ae928a9c1af620487488110eec816b14e23ec` | `16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5` |
| `2.37.2` | `edb1f7efc92ecacdef51aafb4d9d5054ce10604f` | `b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa` |

Container inspection also verified that each running container's image ID matched its inspected
official image. The completed captures used `abs-contract-e146c642` and `abs-contract-ffee9eb4`.
The local `.build/recent-episodes-captures/{2.26.0,2.37.2}/` directories retain exact response bytes
(`normal.json`, `empty.json`, `wrong-library.txt`, `expanded-item.json`, `items.json`, `libraries.json`,
`status.json`), complete `image.json`/`runtime.json`, `verification.json` and `cleanup.json`.
The worktree-local `.build/recent-episodes-capture.py` runs the existing harness and only GETs
after login/standard seed initialization. No extra users, progress or episode mutations are added.

Observed on **both** pins:

- Normal `limit=50&page=0`: exactly one episode, with numeric `limit: 50`, `page: 0`.
- Empty `limit=1&page=1`: `{"episodes":[],"limit":1,"page":1}`.
- Book-library GET: HTTP 404. Neither successful response has `total`.
- The row's episode/library-item/library identities match the scanned seed. Its nested podcast
  has `metadata.title: "Synthetic Cast"` and `episodes: []`; there is no per-user progress.
- Both `audioTrack.index` values are **1** (also in expanded-item GET); duration is `20.088` on
  2.26.0 and `20` on 2.37.2. The content URL identifies the item's audio-file inode.
- `publishedAt` and `pubDate` are explicitly **null** on this scanned, non-feed seed.
  One row does not establish publication ordering or multi-row live paging.

The initial controller-only string-echo assumption was disproved by capture. The first local
capture checks failed on that assumption; their raw proof remains in
`.build/recent-episodes-initial-captures/`, and both initial containers were removed.
The full route chain explains the numeric wire values: `ApiRouter.js:92` applies library middleware,
which calls `Number()` before the controller. String paging is tested only as decoder compatibility.

| Source evidence | 2.26.0 | 2.37.2 |
| --- | --- | --- |
| Route and middleware | [route](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/routers/ApiRouter.js#L92), [normalization](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/LibraryController.js#L1469-L1488) | [route](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/routers/ApiRouter.js#L92), [normalization](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/LibraryController.js#L1475-L1494) |
| Controller | [1285–1298](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/LibraryController.js#L1285-L1298) | [1283–1296](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/LibraryController.js#L1283-L1296) |
| Selection and serialization | [506–558](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/utils/queries/libraryItemsPodcastFilters.js#L506-L558) | [506–558](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/utils/queries/libraryItemsPodcastFilters.js#L506-L558) |
| Audio track | [184–190](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/models/PodcastEpisode.js#L184-L190) | [184–191](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/PodcastEpisode.js#L184-L191) |

Source selects unfinished episodes in descending publication order. The controller's omitted-limit
default is numeric zero; source suggests zero rows, **not unlimited**. Omitted limit, invalid numeric
queries and negative pages were not probed. The native endpoint always supplies its default limit.

The two `ABSAPITests/Fixtures/recent-episodes-*.json` files are complete sanitized normal responses,
not reconstructed examples: only episode/podcast/item/library IDs, inode and its content URL are
replaced. Recursive comparison against raw captures verified every key, array length, scalar type
and other value unchanged, including timestamps and nulls. Checked-in tests require the single raw
row, exact decoded identities/count, independently decoded episode/podcast/audio track, library ID,
duration and publication values. Live tests do the same against the real raw GET and production
endpoint result, so lossy row or optional-podcast failures cannot pass silently.
Derived mixed/all-malformed payloads are explicitly labeled unit data; they are not live captures.

Executed from the owned worktree with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
and `MISE_TRUSTED_CONFIG_PATHS=$PWD`; server commands additionally used
`TMPDIR=$PWD/.build/server-tmp`:

```sh
python3 .build/recent-episodes-capture.py 2.26.0
python3 .build/recent-episodes-capture.py 2.37.2
ABS_RECENT_EPISODES_CAPTURE_DIR=$PWD/.build/recent-episodes-captures \
  swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm \
  --filter 'LibraryResponseDecodingTests|LibraryEndpointsTests|RecentEpisodesResponseTests'
ABS_SERVER_VERSION=2.26.0 scripts/test-server.sh test --filter RecentEpisodesContractTests
ABS_SERVER_VERSION=2.37.2 scripts/test-server.sh test --filter RecentEpisodesContractTests
ABS_SERVER_VERSION=2.26.0 mise run test:server
ABS_SERVER_VERSION=2.37.2 mise run test:server
mise run lint
mise run xcproj:check
mise run test
git diff --check
```

Focused package run: 32 tests, no skips. Each focused server run: 3 executed, no skips.
Each full server run reports 70 tests: **69 executed/passed and one existing series-fixture skip**.
The unchanged `LibraryContractTests.podcast` index assertion passed on both pins; no correction was
needed. Default package-suite configuration skips are not live evidence. Mandatory lint, project
canonicalization and package/tool/macOS app tests passed. No dependencies were manually restored.
The mandatory package run reported 2,206 tests: 2,137 passed, 69 skipped (67 server configuration,
one opt-in OSLog test and one Keychain test). Tools: 24 passed, none skipped. App: seven test
functions passed (21 executions including parameterized cases), one Keychain test skipped.
Harness traps removed all eight exact owned capture/test containers and their `abs-contract.*`
data directories, including failed initial capture attempts; raw proof remains local for review.
SwiftPM may leave its own empty temporary directories/locks in the owned TMPDIR.
This is API contract acceptance only, not UI/device or parent-issue completion.

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
