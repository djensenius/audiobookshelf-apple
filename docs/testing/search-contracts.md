# Owned search contracts

`SearchContractTests` exercises production `LibraryEndpoints.search` and `LibrarySearchResults`
against disposable, independently owned book and podcast libraries. It adds no production admin
API, model change, dependency, target, permission-policy expansion or offline fixtures.
Authentic sanitized offline fixtures are a separate follow-up (#251).

## Run and select

From the owning worktree:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export MISE_TRUSTED_CONFIG_PATHS=$PWD
mkdir -p .build/server-tmp
export TMPDIR=$PWD/.build/server-tmp

ABS_SERVER_VERSION=2.26.0 scripts/test-server.sh test --search-contract
ABS_SERVER_VERSION=2.37.2 scripts/test-server.sh test --search-contract
ABS_SERVER_VERSION=2.26.0 mise run test:server
ABS_SERVER_VERSION=2.37.2 mise run test:server

ABS_SERVER_BACKEND=node ABS_SERVER_VERSION=2.26.0 \
  mise exec node@20 -- scripts/test-server.sh test --search-contract
ABS_SERVER_BACKEND=node ABS_SERVER_VERSION=2.37.2 \
  mise exec node@20 -- scripts/test-server.sh test --search-contract
```

Default full runs execute **two sequential processes on the same freshly started server**:

1. `swift test … --filter ABSServerContractTests --skip SearchContractTests`
2. `swift test … --filter SearchContractTests`, with owned-search mode exported only now.

The first failure stops the script; the second failure also propagates through the cleanup trap.
The explicit focused mode accepts no additional Swift arguments. Existing unrelated focused
selectors, e.g. `test --filter LibraryContractTests/libraries`, run just that selection.
`serve` remains manual-use mode and never exports owned-search authorization.
The installed SwiftPM accepts regex `--filter` and `--skip`; executed identities, not merely
`swift test list` output (which lists unselected tests too), establish selection.

The three live identities are `ABSServerContractTests.SearchContractTests/completeSearch()`,
`queries()` and `failureCleanup()`. The suite is serialized. It does not use `.requiresServer`,
because an explicitly requested run with no server must **fail**, not skip.
Without `ABS_SEARCH_CONTRACT_MODE`, all three report “Owned search NOT RUN”; these skips are
never acceptance evidence. The two `SearchContractGateTests` are pure no-network configuration
checks and can run in ordinary package tests.

## Ownership and fixtures

Only the harness exports `ABS_SEARCH_CONTRACT_MODE`, `ABS_SEARCH_OWNERSHIP`,
`ABS_SEARCH_OWNED_URL`, `ABS_SEARCH_BOOKS`, `ABS_SEARCH_PODCASTS`, `ABS_SEARCH_TOKEN` and
`ABS_SEARCH_PROVENANCE`. Inherited values are cleared before argument routing.
Do not set these manually to authorize writes against an existing server.

Before login, configuration requires explicit mode, credentials, matching ownership/token,
the exact same configured and owned `http://127.0.0.1:<port>` URL, valid disjoint folder layout
and verified source provenance. Missing/empty/malformed values fail. `/status` must match the pin;
before creating libraries, actual seed folders are also checked for **either-direction string
prefix overlap**, not just path-component ancestry.

The harness independently generates sine tones with existing ffmpeg tooling:
two book directories (30 and 40 seconds) and one podcast directory with two episodes (20 and
40 seconds). These are outside the seeded `/audiobooks` and `/podcasts` roots, under
`/search-fixtures/{books,casts}` in Docker's read-write mount, or the corresponding owned
temporary host paths in node mode. No shared files or hardlinks. One generated search token is
embedded in both episode filenames and ID3 titles; episodes are never renamed with podcast PATCH.

Each fixture creates two libraries with `disableWatcher: true`, registers raw IDs before model
decoding, and initiates each scan **once**. It polls persisted `lastScan` and `lastScanVersion`
with cancellation checks and a 60-second deadline. HTTP 200 or item count alone cannot establish
completion. Exact counts/identities and episode media are checked before PATCHing only owned
metadata. Later scans/watchers are not used to make metadata “settle”.

Two asymmetric books establish shared/unique authors, narrators, tags and genres; shared series
sequences 1/2 and a unique series sequence 7. Independent item detail, author membership and
series `include=progress` reads establish the ledger. Ordinary users perform searches.
`ContractSeed` selection and `LibraryContractTests`' exact count of two libraries are unchanged.

## Wire assertions

| Library | Exact groups | Default owned membership |
| --- | --- | --- |
| Book | `book`, `authors`, `series`, `narrators`, `tags`, `genres` | Two books; two of every other group, with shared/unique counts 2/1 |
| Podcast | `podcast`, `episodes`, `tags`, `genres` | One podcast, two distinct episodes, one tag and genre |

Full raw responses are captured before decoding decisions. Assertions require exact group
keys, lengths, raw scalar types and fixture identities, then compare raw/decoded ordered rows.
Every nested item/media/episode and series member is independently decoded, so lossy containers
cannot hide a valid row. Unordered groups are compared as sets without inventing tie ordering.

Verified on both official pins and both node pins:

- Author/narrator counts use numeric `numBooks`; tags/genres use numeric `numItems`.
- Series search members are nonexpanded books with **empty** author/series arrays, no item-level
  series or per-series sequence; expanded book results retain the independently verified sequences.
- Podcast wrappers have empty `media.episodes`. Episode wrappers carry a full `recentEpisode`,
  whose identity, file/track data, duration, size and timestamps agree with item detail.
- Both scanned episodes have audio-track index **1** on both versions, not a presumed old-version
  null. Locally scanned files have explicit JSON null `pubDate` and `publishedAt`, as set by
  `PodcastScanner`; these are asserted as present nulls, not accepted as missing fields.
- Bounded read-only checks cover per-group limit 1, explicit 12, zero's server-default behavior,
  surrounding spaces (sent unchanged), no matches, missing library 404 and absent/empty query 400.
  No trimming, clamping, stricter `NameMatch`, fuzzing or new permission policy is introduced.

Source: `advplyr/audiobookshelf` pins
[`264ae928a9c1af620487488110eec816b14e23ec`](https://github.com/advplyr/audiobookshelf/tree/264ae928a9c1af620487488110eec816b14e23ec)
and [`edb1f7efc92ecacdef51aafb4d9d5054ce10604f`](https://github.com/advplyr/audiobookshelf/tree/edb1f7efc92ecacdef51aafb4d9d5054ce10604f).
Relevant paths are `server/utils/queries/libraryItemsBookFilters.js`,
`libraryItemsPodcastFilters.js`, `authorFilters.js`, `server/controllers/LibraryController.js`,
`LibraryItemController.js`, `SeriesController.js`, and `server/scanner/LibraryScanner.js:94–130`.
Persisted scan completion is saved only after a noncancelled scan, before `librariesScanning` clears.

## Provenance, captures and cleanup

Docker startup inspects all official image labels and RepoDigests, requiring the exact revision
and digest in the [canonical provenance table](server-contracts.md#collection-write-contract-and-capture-provenance).
Missing/mismatching revision is a failure, never a guessed fallback. Node startup verifies the
fresh checkout's exact HEAD and clean status before its existing dependency installation.
Both backends check the actual `/status.serverVersion`. Full runs on unreviewed versions fail
closed; a focused ordinary selector retains legacy behavior without enabling search writes.
The existing scheduled workflow runs the **full** node-backed harness on both reviewed pins.

Optionally set `ABS_SEARCH_LIVE_CAPTURE_DIR=$PWD/.build/search-live/<backend>-<version>-<run>`.
Only a path inside this worktree's `.build` is accepted. Per-fixture UUID directories contain
complete response bytes for provenance/status, scan completion, create/PATCH/detail/search,
the independently verified ledger, seed before/after snapshots and cleanup results. No response
is trimmed or replayed for capture. Assertions and cleanup do not depend on capturing.
Never commit local captures or credentials.

Cleanup deletes only the two exact owned libraries, then the owned user, and requires exact-ID
GET 404 for libraries, items, authors, series and user. This cascade was actually verified on
both pins, not inferred solely from source. All three seed item bodies and the entire seed
library listing must be unchanged. The deliberate-body-error test verifies every absence again
and catches only its original error; teardown errors are separately reported.

Cleanup uses five-second request timeouts and a bounded deletion/verification loop. On cancellation,
an uncancelled cleanup task attempts persisted scan completion for five seconds per pending scan.
If completion cannot be proved, deletion is deferred with a failure; elapsed time does **not**
mean the scanner stopped. The outer owned-server trap is final containment. Do not remove
another worker's containers, processes, generated paths or worktrees.

The outer trap now registers Docker's full container ID through `--cidfile`, requires successful
removal **and** a successful empty exact-ID inventory query, and never interprets daemon/CLI
failure as absence. Node shutdown checks this shell's registered child jobs (including stopped
jobs), allows three seconds after TERM, escalates only that PID to KILL, then allows two seconds
to verify exit. It never waits on an active child. Already exited children need no signal.
Docker removal, inventory and diagnostic commands each have a five-second execution deadline,
two seconds to verify a forced CLI stop, and at most one second to drain output. A private,
unlinked FIFO prevents an unkillable CLI from holding a command-substitution output pipe open.

If containment is unverified, the trap reports the exact ID/PID and owned data directory,
retains that directory, and fails an otherwise successful run. An existing primary exit code
(including 37, 130 or 143) is preserved while cleanup errors are reported. Missing Docker ID
after a partial start is uncertainty, not permission to delete data or remove by name.

Run the durable no-server regression checks with:

```sh
python3 scripts/test-server-cleanup-tests.py
```

These standard-library tests execute the actual harness trap/runner with owned fake Docker and
Node processes. They cover removal/verification failure and hangs, a verifier that cannot be
killed, partial-start ID recovery, missing ID, normal/already-exited/stopped/TERM-ignoring Node
children, uncertain-stop data retention, primary-error preservation and focused selector routing.
Each has an eight-second outer deadline; final test cleanup verifies and kills only its registered
fake PIDs before removing its own temporary directory. No real Docker or API mutation occurs.

Validation also includes `bash -n scripts/test-server.sh`, `mise run lint` (ShellCheck included),
`mise run xcproj:check`, `mise run test`, and `git diff --check`. Default package skips are not
search validation. Hosted schedule execution, UI/device acceptance and offline fixtures are
separate from these live contracts.
