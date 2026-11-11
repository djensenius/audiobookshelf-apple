# Owned search contracts

`SearchContractTests` exercises production `LibraryEndpoints.search` and `LibrarySearchResults`
against disposable, independently owned book and podcast libraries. It adds no production admin
API, model change, dependency, target or permission-policy expansion. #258 adds complete
filter fixtures and positive filter checks. Authentic offline search fixtures are separate (#251 for 2.26.0,
#259 for 2.37.2); see the offline evidence section below.

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

The live identities are `ABSServerContractTests.SearchContractTests/completeSearch()`,
`queries()`, `failureCleanup()` and `scanPrimedPodcastLanguageDiscrepancy()`.
The last is explicitly a cache-bug characterization, not positive language acceptance.
The suite is serialized. It does not use `.requiresServer`,
because an explicitly requested run with no server must **fail**, not skip.
Without `ABS_SEARCH_CONTRACT_MODE`, they report “Owned search NOT RUN”; these skips are
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

## Offline search evidence (2.26.0)

`LibrarySearchResultsTests` consumes complete `search-book-2.26.0.json` (798 lines)
and `search-podcast-2.26.0.json` (508 lines), not production-model re-encodings.
They retain every response key and row. The focused Docker runtime-bound recapture used
`GET /api/libraries/<owned-library>/search?q=<owned-token>` with no explicit limit,
as an ordinary user. `SearchContractFixture.request` requires HTTP 200 **before**
`completeSearch` saves either body; there is no separate retained HTTP-status sidecar.

Source is `advplyr/audiobookshelf` 2.26.0 revision
`264ae928a9c1af620487488110eec816b14e23ec`, official image digest
`sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5`.
The matching provenance includes full image labels/RepoDigests; `/status.serverVersion`
is `2.26.0`. Original SHA-256 values (before whitespace changes or sanitization):

| Body | SHA-256 |
| --- | --- |
| Book search | `f4748dc01f4ea8ff5f1e946de3334265dfd281ca521d2b67e788ae6ab815d139` |
| Podcast search | `948e1c7d4f833a6f9820d0ca8c6f8ea621dabeedef3a4cd665c5836bed197ee6` |
| Independent verified ledger | `2b9267ff7649acbf07e9f4e482d4f3251d426537863bff47ab3dedf4ed383ab0` |

The unchanged harness ran once with `ABS_SERVER_BACKEND=docker ABS_SERVER_VERSION=2.26.0`
and `scripts/test-server.sh test --search-contract` under `nice -n 10`. A private bounded
observer forwarded Docker arguments/output/exit status unchanged, registered the exact full
owned container ID, and inspected it while running. Its `.Image` equaled both the actual
and canonical image `.Id`; both inspections retained the full labels/revision and canonical
RepoDigest above. The same owned port returned HTTP 200 `/status` with version `2.26.0`.
Complete command/nonsecret environment/output and runtime records are retained privately.
The focused suite passed 3 tests/0 skips; all 30 exact-ID 404s and 12 unchanged seed pairs
were checked, with zero cleanup failures. The harness verified exact owned container removal.

Private originals and exact source/request/hash mapping remain under the owning worktree's
ignored `.build` evidence. The two fixtures and independent ledger share one capture namespace.
Sanitization replaces only library/folder/item/media/author/series/episode UUIDs with stable
fixture identities, item IDs inside `contentUrl`, and the owned query-token prefix with
`Search Fixture` in names, flattened metadata, tags/genres/narrators, filenames/paths and
ID3 `tagArtist`/`tagTitle`. Synthetic container paths and inode strings are retained.
A recursive original/fixture comparison permits only those explicit string substitutions;
all key sets/order, arrays/order/lengths, scalar types, nulls, timestamps, sizes, durations,
codec metadata and other nonidentifying values are unchanged. No credentials are fixtures.
Earlier captures and candidate evidence remain immutable, but no earlier response fragments
are used here. The recapture has fresh IDs, inodes and timestamps, including distinct library
file timestamps; its observed Book 1 author order differs from the earlier candidate.

Expectations are independently transcribed from item, author-membership and series-progress
detail reads and their verified ledger. Every raw group/element and nested model is decoded
separately, then compared to complete ordered typed expectations, in addition to whole-response
equality. Captured search order is not a cross-run ordering guarantee: Book 1's expanded
series are unique/shared, while detail series and both author arrays list shared/unique.
Shared/unique counts are 2/1 (`numBooks` for authors/narrators, `numItems` for tags/genres).
Series members have empty author/series arrays, no per-series sequence, and no expanded
tracks/duration/size. Podcast wrappers have empty episodes and media size 0, but item size
121046. Episode hits contain `recentEpisode`, null episode `index`, audio index 1, and
explicit null `pubDate`/`publishedAt`. No minified media counts are present in this pair.
Unsupported wire fields such as ID3 `metaTags`, `timeBase` and `oldEpisodeId` remain intact;
retention is not a claim that the Swift models expose them. No malformed input was captured;
existing derived compatibility tests remain separate and production tolerance is unchanged.

The server applies limit 12 **per group**, not to the total response (source: pinned
`LibraryController` search handler and its book/podcast/author query helpers; corroborated
by the owned limit 1/0/12 contracts). Missing/empty queries and no-match responses belong
to live contracts, not invented offline capture variants.

Normal validation uses the issue's focused Swift filter. For additional unmodified-original
proof, set `ABS_SEARCH_RESPONSE_CAPTURE_DIR` to the private original root containing
`2.26.0/{26-verified-ledger,27-book-search,28-podcast-search}.json` and run the same filter.
Bundled checks still execute; original mode additionally verifies the ledger and both bodies
using original identities. This mode is specific to the documented capture, not arbitrary runs.
Retained #250 live evidence covers both pins/backends, focused and full: reported 3 search
tests/0 skips, with full runs first executing 71 ordinary tests/1 known skip. No live matrix
was rerun: only the one focused 2.26.0 runtime-binding recapture above was needed.
#259 supplies the separate 2.37.2 fixtures.

## Filter metadata: positives and separate cache characterization (#258 / #263)

**#263 remains open and blocked:** successful nonempty podcast-language filter acceptance
has not been established. An observed empty filter array is not an unsupported-dimension rule
and is not successful positive coverage. Closing #258 must not close #263/#222.

The owned generator places metadata.json beside both book files and the podcast episodes.
Book tags/genres/narrators exactly match final shared/unique PATCH values at scan time.
First declares First Publisher/en/1984; Second declares Second Publisher/fr/2007.
Independent decade expectations are string values 1980 and 2000. Podcast declares
its final token-derived tag/genre and language de; audio genre already matches.
No sidecar authors, series or titles are supplied. Both audio artist tags remain Shared Author.
Each pre-PATCH expanded book read strictly checks retained Shared Author and empty series;
PATCH order and asymmetric search cardinalities are unchanged.

Library scanning primes the in-memory filter cache BEFORE it scans any items. The cache's
30-minute early return precedes DB change detection. Incremental additions fill arrays while
cached count markers can remain zero. Final metadata PATCHes do not make tag/genre/narrator
cache data current; matching scan-time metadata avoids that unrelated stale-PATCH scenario.

There are two deliberately distinct assertions:

- `completeSearch`: positive nonempty book authors, series, narrators, genres, tags, languages,
  publishers and decades; positive podcast tags/genres. Independent expanded-item/author/series
  reads establish identities and declared values. Expected-empty podcast author/series/narrator/
  publisher/decade groups are verified. No nonempty podcast-language success is claimed.
- `scanPrimedPodcastLanguageDiscrepancy`: same-run independent podcast language MUST equal de,
  while the observed wrapper/dedicated filter languages are empty on both recorded pins.
  Its test name says CHARACTERIZATION and explicitly leaves #263 unmet. No caught/ignored
  positive failure, expected-failure wrapper, skip or changed decoder is used.

Both require complete raw objects before trusting the native wrapper fallback or lossy arrays.
All author/series rows are individually decoded and their complete modeled values compared in
exact wire order. Every string array is strictly read, duplicate-free and order-preserving
against its DTO. Semantic membership uses duplicate-free sets, never an invented cache sort order.
The wrapper's raw filterdata equals the dedicated JSON, and both typed filter values must match.
Required millisecond loadedAt stays Int?; issues/user playlists stay numeric zero for this fixture.

### Actual preparation captures (2026-11-11 UTC)

Both focused Docker processes ran the pre-assertion capture preparation: **3 passed, 0 failed,
0 skipped** each. Those are existing search tests, not passing nonempty podcast-language tests.
The independent original positive audit on EACH pin returned **378 checks passed, 1 failed,
exit 1**, specifically expected `["de"]`, actual `[]`. These red reports remain immutable.
The newer audit's only wire-shape adaptation is the source-backed absent provider field.

| Pin | Full source revision | Official digest and running `.Image` |
| --- | --- | --- |
| 2.26.0 | `264ae928a9c1af620487488110eec816b14e23ec` | `sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5` |
| 2.37.2 | `edb1f7efc92ecacdef51aafb4d9d5054ce10604f` | `sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa` |

Registered full running container IDs, respectively:
`94b958c00748c25e5b5eef009eda0a36190ce10b951128100fe293ded3a6a95f` and
`911828a4a7505ce00118dbb2f45e80e540368d7274585cc2e5c22f9773fc19c5`.
While-running inspection proved `.Image == actualImageID == canonicalImageID` with exact
RepoDigest, full labels/revision and actual HTTP200 /status version. Tag inspection alone
was not used as runtime proof. Exact registered-ID inventory and owned data removal succeeded.
All three fixture cleanups per process verified all ten registered resources absent and four
ordinary seed snapshots unchanged. No unrelated resource was inspected for cleanup or removed.

For each pin, originals include four actual ordinary-user HTTP200 GETs: book/podcast
`/api/libraries/:id?include=filterdata` through the native endpoint, and test-only raw
`/api/libraries/:id/filterdata`. Bodies were not replayed for capture. Response headers/status
come from the actual URLSession response; originals, command/env/output, ledger/item details,
generated inventory and cleanup live privately under the owning worktree's .build.

Observed cache loadedAt values (book/podcast):
2.26.0 `1794365238238` / `1794365238493`;
2.37.2 `1794366009137` / `1794366009382`.
Each was unchanged between wrapper and dedicated and preceded scan completion.
All four unmodeled count fields are present numeric zero: bookCount/authorCount/seriesCount/
podcastCount. They are NOT current DB totals. Wrapper customMetadataProviders is present empty
on 2.26.0 and absent on 2.37.2; no synthetic version differences were introduced.

Expanded libraryFiles include exactly audio + metadata.json for each book and two episodes +
metadata.json for the podcast. Added sidecars are 335/221/114 bytes; item totals include them
while media sizes count audio only. File inventories/independent size sums are asserted, not
dropped. Ordinary generated media are unchanged. Metadata additions do not rewrite historical
#251 search fixtures.

### Complete fixtures and optional original proof

Eight `ABSAPITests/Fixtures/filter-{book,podcast}-{wrapper,dedicated}-{version}.json` files
are full readable bodies, not trimmed/minified summaries. Only exact JSON-pointer-allowlisted
library/folder/author/series IDs and the identifying query-token prefix were replaced.
Every key, absent/null distinction, numeric/boolean/string type, timestamp and array order/length
is unchanged. Paths were already synthetic and were not altered; no URL occurs in these bodies.
The independent private proof records original SHA256s, each old/new identifying value and
its exact pointer. Semantic groups retain all valid elements.

`NonemptyFilterResponseTests.completeBodiesPreservePositiveGroupsAndOrderedDTOs` validates
both bundled endpoints per media type/pin. The separately named offline language characterization
compares the observed empty arrays to the declared de, without pretending bundled filter bodies
contain expanded item evidence. Optional original verification also checks every independent
pre/post expanded item, retained author, inventory and the actual podcast language.

For optional original verification, set `ABS_FILTER_CAPTURE_DIR` to the private proof root,
with per-version directories containing the four `{book,podcast}-{wrapper,dedicated}.json`
originals, six `{first,second,podcast}-{before,after}.json` expanded item reads and manifest.json.
Run `swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm --jobs 2
--filter NonemptyFilterResponseTests`. The test always checks bundled fixtures as well.
The manifest holds each original hash and exact allowed substitutions; verification traverses
every JSON value and rejects changes outside identifying string leaves.

Required validation includes focused offline/original modes, owned search on both Docker/Node
pins, existing cleanup/generator regressions and serial mandatory checks. Preparation capture
passes alone are not evidence that the final assertion-bearing tests passed. The generator
regression checks exact seven-file owned inventory, unchanged ordinary seed sentinels and
declared sidecar/audio tags. Default live skips are not live evidence.

Source at the full pins above: `LibraryScanner.js:143-156` primes the cache;
`libraryFilters.js:445-452` / `450-457` returns it early. Podcast creation calls only
genres/tags helpers at `PodcastScanner.js:347-348` / `358-359`; cold podcast query
`libraryFilters.js:524-546` / `529-551` explicitly adds language.
Books do call the language helper at `BookScanner.js:602` / `613`.
Wrapper/dedicated routes share the same query (`LibraryController.js:221-231,880-882`
/ `221-230,878-880`). No cold-cache execution, expiry, rescan, restart, bypass or client
normalization is exercised. This records the server omission; it does not repair it.

## Offline search evidence (2.37.2)

`LibrarySearchResultsTests` also consumes complete `search-book-2.37.2.json`
(806 readable lines) and `search-podcast-2.37.2.json` (514), retaining every key,
row and nested value. They are genuine sanitized responses, not model re-encodings.
Source: `advplyr/audiobookshelf` 2.37.2 revision
`edb1f7efc92ecacdef51aafb4d9d5054ce10604f`, canonical image digest
`sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa`.

The unchanged harness ran once with `ABS_SERVER_BACKEND=docker`,
`ABS_SERVER_VERSION=2.37.2` and `scripts/test-server.sh test --search-contract`
under `nice -n 10`. A private transparent Docker observer retained the exact
registered container ID and inspected it while alive, before and after the
status observation. Its `.Image` matched both the actual and canonical image
`.Id`, with matching full revision/source/version labels and RepoDigest above.
Actual GET `/status` on that owned port returned HTTP 200 and version `2.37.2`;
its body, status and response headers are retained privately. The observer
resolved real executables before prefixing PATH. A declared private Swift
forwarder added only `--jobs 2` to the harness's focused test invocation.
No production, tracked harness, shared seed or endpoint behavior changed.

The focused suite passed 3 tests/0 skips. Across its three owned namespaces,
all 30 exact-ID absence checks returned 404, all 12 seed before/after pairs were
unchanged and cleanup reported zero failures. The harness verified exact owned
container removal; an independent successful exact-ID inventory was empty, the
registered harness process exited and its owned temporary data directory was
absent. Full commands, output, runtime inspection, cleanup and hashes remain
private. No unchanged live backend/version matrix was rerun.

Both searches were ordinary-user GET requests with the owned query token and no
explicit limit. `SearchContractFixture.request` requires HTTP 200 before saving
either complete body. This is code-enforced search success, NOT a separately
retained search status/header sidecar; the observer's sidecar covers `/status`
only. Pair, ledger and independent item/author/series details share one namespace:

| Original body | SHA-256 before sanitization or whitespace changes |
| --- | --- |
| `27-book-search.json` | `600a59a033bbd41c6abd4940d89121a4ead76114baece6eb5aa8b02be7414d25` |
| `28-podcast-search.json` | `192aa02cafc3d45da189d50ecefe9e3fdc060e4fb09b6b557c10b316c82aead2` |
| `26-verified-ledger.json` | `8e3d435343c90ccbd69eafd61b4443b69bc7edf8005565958b3fa9c76cffd836` |

Earlier #250 captures lacked the running-container image binding and were used
only for private shape/budget preparation. All earlier originals are unchanged;
no older response fragments or ledger values are used in this newer pair.
Sanitization substitutes only explicit identity UUIDs, item IDs within content
URLs and the owned query token in names/flattened metadata/ID3 fields/paths.
Synthetic paths, inode strings, timestamps, sizes, durations and all other
nonidentifying values are retained. The separate private recursive audit compares
key presence/order, scalar types, nulls and every array length/order/value; its
negative mutations must fail. Original bytes and explicit substitutions stay
private and are never uploaded.

Newer expanded books include item `numFiles: 1` and media `numTracks: 1`,
`numAudioFiles: 1`, `numChapters: 0`. Series members still omit these counts and
expanded tracks/duration/size, have empty author/series arrays and no per-series
sequences. Podcast wrappers include item `numFiles: 2` and media `numEpisodes: 0`
with empty episodes; independent detail contains two episodes. Episode matches
remain in `libraryItem.recentEpisode`, with null episode index/publication fields
and audio index 1. Author/narrator counts use `numBooks`; tags/genres use
`numItems`, with asymmetric shared/unique counts 2/1. This capture's durations
are 30/40/20/40 seconds, not the older pair's 30.096/40.104/20.088/40.104;
this is an observation, not an asserted universal version rule.

Independent raw details and their verified ledger supply identities and values;
search determines only its projection/order. The newer Book 1 search author order
is unique/shared, while independent detail is shared/unique. Its search and
detail series are both shared/unique. Fresh inodes and timestamps, including
distinct audio-added and item-last-scan times, are not normalized. Strict
per-element/nested decoding compares complete ordered typed expectations and
selected raw fields, in addition to whole-response equality. Existing synthetic
compatibility cases remain separate; no malformed-input version differences
are invented.

Both bundled pairs always run in the focused `LibrarySearchResultsTests` suite.
`ABS_SEARCH_RESPONSE_CAPTURE_DIR` alone preserves legacy additional 2.26.0
original verification. Set `ABS_SEARCH_RESPONSE_CAPTURE_VERSION=2.37.2` to
require newer originals, or `all` to require both. Each selected version reads
`<root>/<version>/{26-verified-ledger,27-book-search,28-podcast-search}.json`.
Unknown/empty selectors, a selector without a root, an empty root, missing files
and decoding failures fail, without a bundled fallback for original evidence.
Run the whole focused suite, not a filter selecting only the other version.
This mode checks the specific documented runs, not arbitrary future captures.
Swift original checks cover typed expectations and selected raw fields; they
are NOT recursive original-to-bundled verification. That proof belongs to the
separate private recursive audit and its negative mutations.
