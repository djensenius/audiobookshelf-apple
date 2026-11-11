# Series detail contracts (#242)

This is the bounded API child of #222, not a series UI or a library-scoped route
migration. `SeriesEndpoints.detail(id:includeProgress:)` defaults to progress.
`ItemEndpoints.series(id:)` and `ABSCore.Series` remain unchanged.

## Source and real-response evidence

Public upstream: **advplyr/audiobookshelf**, not either Apple/client repository.

| Server | Source commit | Captured Docker image digest (`ghcr.io/advplyr/audiobookshelf`) |
| --- | --- | --- |
| 2.26.0 | `264ae928a9c1af620487488110eec816b14e23ec` | `sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5` |
| 2.37.2 | `edb1f7efc92ecacdef51aafb4d9d5054ce10604f` | `sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa` |

Pinned source:

- [2.26 controller](https://github.com/advplyr/audiobookshelf/blob/264ae928a9c1af620487488110eec816b14e23ec/server/controllers/SeriesController.js#L35-L62)
  and [2.37 controller](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/SeriesController.js#L35-L62):
  flat `toOldJSON()` metadata plus sibling `progress`; no books.
- The controllers were independently fetched and are byte-identical:
  SHA-256 `e6bc31c1e77528f14059eff5b391aab8bb0bad72bd4db37482cbaf9ce2e5d7c5`.
- [Middleware, lines 95–119](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/SeriesController.js#L95-L119):
  unknown series or no accessible books returns 404. The GET has no separate
  403 policy; the permission checks there concern mutations.
- [Serializer, lines 168–178](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/Series.js#L168-L178):
  `id`, `name`, `nameIgnorePrefix`, `description`, `addedAt`, `updatedAt`, `libraryId`.
  Timestamps are epoch milliseconds.
- [Book filtering, lines 1079 onward](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/utils/queries/libraryItemsBookFilters.js#L1079):
  caller-accessible books, including explicit/tag permission filtering.
- [User progress lookup](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/User.js#L703)
  uses **book media IDs**; the controller returns **library-item IDs**.
  Stored `isFinished` flags determine completion; missing progress rows are unfinished.
- [Router](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/routers/ApiRouter.js#L228):
  the deprecated `/api/series/:id` route remains supported. Use an access bearer
  token on 2.37.2, not a refresh token. Authentication is existing production behavior.

On 2026-11-10, **before writing the DTO or fixtures**, the script below separately
started each release, generated two 30-second sine-tone MP3 books, scanned them,
and associated them with one uniquely named series. It verified each expanded
item's library ID, media ID, sequence and series membership independently of the
series response. All four item/media IDs were distinct. Only the first book was
marked finished for capture.

Each release independently produced the checked-in
`Tests/ABSAPITests/Fixtures/series-detail-<version>.json`. They happen to be identical
after sanitization; neither version was manufactured from the other. No keys were
trimmed. UUIDs became `series-fixture`, `library-fixture`, `item-one`, `item-two`;
the unique series name became `Series Evidence Fixture`; timestamps became
`1700000000000`. The response contains no paths, users or authentication data.

Both real **omitted-include** responses were also captured and asserted equal to
the corresponding included response minus `progress`:

```json
{
  "id": "series-fixture",
  "name": "Series Evidence Fixture",
  "nameIgnorePrefix": "Series Evidence Fixture",
  "description": null,
  "addedAt": 1700000000000,
  "updatedAt": 1700000000000,
  "libraryId": "library-fixture"
}
```

Decoding composes the existing `Series` from the same flat object. Missing/null
progress is nil. A present progress object requires both ID arrays and the boolean.
Only array **elements** are lossy; malformed containers, missing fields and
non-boolean completion fail. The server boolean is never recomputed from surviving
IDs. Metadata decoding and unknown-field tolerance follow the existing core model.

## Live contract enablement

`SeriesDetailContractTests` uses production endpoints, progress updates and
`ContractServer.withUser`. Two fresh users demonstrate:

1. Both independently verified books belong to the expected series/library and
   use library-item IDs, not media IDs, in the aggregate.
2. No progress rows means unfinished; default inclusion and explicit omission work.
3. One finished book means partial completion.
4. A stored percentage of 1 without a finished flag still means partial completion.
5. Both finished means complete; un-finishing one reverses completion.
6. Each user's changes remain isolated, in both directions.
7. An unknown series returns 404 through the production endpoint.

The standard shared seed deliberately has no series. Its run executes the
unknown-series test but **skips the owned two-book test** with a specific message.
That skip is not acceptance evidence. The owned run below executes both tests
without skips on **each** release. No `ContractSeed` or harness changes are needed.

| Environment | Meaning |
| --- | --- |
| `ABS_TEST_SERIES_FIXTURE=1` | Explicitly enable the owned-fixture contract |
| `ABS_TEST_SERIES_ID` | UUID of the unique series |
| `ABS_TEST_SERIES_ITEM_IDS` | Two distinct library-item UUIDs, comma-separated, sequence order 1,2 |
| `ABS_TEST_SERVER_URL`, `ABS_TEST_USERNAME`, `ABS_TEST_PASSWORD`, `ABS_TEST_SERVER_VERSION` | Existing contract-server configuration |

Leave the fixture flag **unset** for the unchanged shared seed. Any present flag
other than `1`, missing/malformed IDs, duplicate IDs, wrong associations or missing
server configuration **fails**, rather than silently skipping the fixture test.
This includes explicit enablement with no server URL. Do not copy credentials into
commands, files or manifests: the setup passes fresh credentials only in the child
process environment. Never run these mutating tests against a personal server.

## Reproduce the owned setup, capture and tests

Requires Docker, Python 3, ffmpeg and the repository's Xcode toolchain. From the
worktree root, copy the Python block below into a scratch script such as
`/tmp/abs-series-242-capture.py` (the implementation session retained that exact
script outside the repository). It contains no secrets or captured private data.
It is a standalone owned-fixture helper, **not** a shared-harness modification.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export MISE_TRUSTED_CONFIG_PATHS="$PWD"
df -h .  # Pause heavy jobs if less than 5 GiB is available.
docker pull ghcr.io/advplyr/audiobookshelf:2.26.0
docker pull ghcr.io/advplyr/audiobookshelf:2.37.2
# Captures only, before implementing/changing DTOs; compare printed image digests above.
python3 /tmp/abs-series-242-capture.py 2.26.0 2.37.2
# Recreates independent servers; captures, then runs the explicit fixture tests.
python3 /tmp/abs-series-242-capture.py --test 2.26.0 2.37.2

# Ordinary unchanged-seed suites (fixture variables must be unset):
ABS_SERVER_VERSION=2.26.0 mise run test:server
ABS_SERVER_VERSION=2.37.2 mise run test:server
# Focused unit coverage and repository gates:
swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm \
  --filter 'SeriesDetailResponseTests|SeriesEndpointsTests'
mise run lint
mise run xcproj:check
mise run test
```

Negative setup check (expected exit 1, not a passing/skipped fixture contract):
with all other `ABS_TEST_*` variables unset, run
`ABS_TEST_SERIES_FIXTURE=1 swift test --package-path Packages/AudiobookshelfKit --scratch-path .build/swiftpm --filter SeriesDetailContractTests`.
It fails with `Set ABS_TEST_SERIES_ID to the owned series UUID`; the unrelated
unknown-series test skips because there is no server.

The helper prints only sanitized responses, image digests and cleanup evidence.
It never prints login results, credentials or manifests. Each run removes **only**
its exact random container and exact temporary directory in `finally`. Interrupt
normally so that cleanup runs. After an untrappable kill, remove only the specific
owned resources identified for that invocation; never use global/wildcard cleanup.
The shared harness retains its own existing cleanup behavior.

```python
#!/usr/bin/env python3
"""Owned synthetic series evidence; run from p3-08b. No credentials are persisted."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def run(version, test):
    assert shutil.disk_usage(".").free > 5 * 1024**3, "Less than 5 GiB free"
    work = Path(tempfile.mkdtemp(prefix="abs-series-242-")).resolve()
    container = "abs-series-242-" + secrets.token_hex(6)
    image = "ghcr.io/advplyr/audiobookshelf:" + version
    password = secrets.token_hex(24)
    token = None
    base = None

    def api(method, path, body=None):
        headers = {"Content-Type": "application/json", "x-return-tokens": "true"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as reply:
                raw = reply.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: HTTP {error.code}") from None
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode()

    try:
        for folder in ("config", "metadata", "audiobooks"):
            (work / folder).mkdir()
        for number, frequency in ((1, 440), (2, 523)):
            title = f"Series Tone {number}"
            book = work / "audiobooks" / "Series Fixture" / title
            book.mkdir(parents=True)
            subprocess.run(
                ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
                 "-f", "lavfi", "-i", f"sine=frequency={frequency}:duration=30:sample_rate=16000",
                 "-ac", "1", "-c:a", "libmp3lame", "-b:a", "16k",
                 "-metadata", f"title={title}", "-metadata", f"album={title}",
                 "-metadata", "artist=Series Fixture", str(book / "tone.mp3")],
                check=True)
        command("docker", "run", "--detach", "--name", container,
                "--label", "abs-series-242=1", "--user", f"{os.getuid()}:{os.getgid()}",
                "--publish", "127.0.0.1::80", "--env", "TZ=UTC",
                "--env", "RATE_LIMIT_AUTH_MAX=0",
                "--volume", f"{work}/config:/config",
                "--volume", f"{work}/metadata:/metadata",
                "--volume", f"{work}/audiobooks:/audiobooks", image)
        port = command("docker", "port", container, "80/tcp").splitlines()[0].rsplit(":", 1)[1]
        base = "http://127.0.0.1:" + port
        for attempt in range(120):
            try:
                api("GET", "/ping")
                break
            except (OSError, RuntimeError):
                time.sleep(1)
        else:
            raise RuntimeError("Server startup timed out")
        status = api("GET", "/status")
        assert status["serverVersion"] == version
        credentials = {"username": "root", "password": password}
        api("POST", "/init", {"newRoot": credentials})
        token = api("POST", "/login", credentials)["user"]["accessToken"]
        library = api("POST", "/api/libraries", {
            "name": "Series Evidence", "folders": [{"fullPath": "/audiobooks"}],
            "mediaType": "book", "icon": "audiobookshelf"})["id"]
        api("POST", f"/api/libraries/{library}/scan")
        for attempt in range(120):
            items = api("GET", f"/api/libraries/{library}/items?minified=1")["results"]
            if len(items) == 2:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Two-book scan timed out")
        items.sort(key=lambda item: item["media"]["metadata"]["title"])
        ids = [item["id"] for item in items]
        series_name = "Series Evidence " + secrets.token_hex(6)
        series_id = None
        media_ids = []
        for number, item_id in enumerate(ids, 1):
            association = {"name": series_name, "sequence": str(number)}
            if series_id:
                association["id"] = series_id
            api("PATCH", f"/api/items/{item_id}/media",
                {"metadata": {"series": [association]}})
            expanded = api("GET", f"/api/items/{item_id}?expanded=1")
            memberships = expanded["media"]["metadata"]["series"]
            assert expanded["id"] == item_id and expanded["libraryId"] == library
            assert len(memberships) == 1 and memberships[0]["name"] == series_name
            assert memberships[0]["sequence"] == str(number)
            if series_id:
                assert memberships[0]["id"] == series_id
            series_id = memberships[0]["id"]
            media_ids.append(expanded["media"]["id"])
        assert len(set(ids + media_ids)) == 4, "Library-item IDs must differ from media IDs"
        api("PATCH", f"/api/me/progress/{ids[0]}", {"isFinished": True})
        included = api("GET", f"/api/series/{series_id}?include=progress")
        omitted = api("GET", f"/api/series/{series_id}")
        assert "books" not in included and "progress" not in omitted
        assert {k: v for k, v in included.items() if k != "progress"} == omitted
        assert set(included["progress"]["libraryItemIds"]) == set(ids)
        assert included["progress"]["libraryItemIdsFinished"] == [ids[0]]
        assert included["progress"]["isFinished"] is False
        replacements = {series_id: "series-fixture", library: "library-fixture",
                        series_name: "Series Evidence Fixture",
                        ids[0]: "item-one", ids[1]: "item-two"}

        def sanitize(value):
            if isinstance(value, dict):
                return {k: 1700000000000 if k in ("addedAt", "updatedAt") else sanitize(v)
                        for k, v in value.items()}
            if isinstance(value, list):
                return [sanitize(v) for v in value]
            return replacements.get(value, value) if isinstance(value, str) else value

        print(f"CAPTURE {version}: expanded membership verified; 2 distinct library-item/media ID pairs",
              flush=True)
        print("IMAGE " + command("docker", "image", "inspect", image,
                                "--format", "{{index .RepoDigests 0}}"), flush=True)
        print("INCLUDED " + json.dumps(sanitize(included), indent=2), flush=True)
        print("OMITTED " + json.dumps(sanitize(omitted), indent=2), flush=True)
        if test:
            assert shutil.disk_usage(".").free > 5 * 1024**3, "Less than 5 GiB free"
            environment = dict(os.environ, ABS_TEST_SERVER_URL=base, ABS_TEST_USERNAME="root",
                               ABS_TEST_PASSWORD=password, ABS_TEST_SERVER_VERSION=version,
                               ABS_TEST_SERIES_FIXTURE="1", ABS_TEST_SERIES_ID=series_id,
                               ABS_TEST_SERIES_ITEM_IDS=",".join(ids))
            subprocess.run(
                ["swift", "test", "--package-path", "Packages/AudiobookshelfKit",
                 "--scratch-path", ".build/swiftpm", "--filter", "SeriesDetailContractTests"],
                env=environment, check=True)
    finally:
        try:
            command("docker", "rm", "-f", container)
        finally:
            shutil.rmtree(work)
        print(f"CLEANUP {version}: removed {container} and {work}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("versions", nargs="+", choices=["2.26.0", "2.37.2"])
    args = parser.parse_args()
    for version in args.versions:
        run(version, args.test)
```
