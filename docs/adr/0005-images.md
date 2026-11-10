# 0005. Cover and image loading and caching

- Status: Accepted
- Date: 2026-11-09
- Issue: #42 (P3-02)

## Context

Covers appear in nearly every part of the app: library grids and lists, item
detail, the player, Now Playing, CarPlay lists, and (later) widgets. Author images
appear in author lists. A library can have 2,000 or more items. This ADR covers
how images are fetched, authenticated, decoded, cached, and shared between those
places. Module placement follows [0001](0001-architecture.md). Now Playing API
choice is [0006](0006-now-playing.md); download mechanics are owned by
`ABSDownloads`.

**Legacy behaviour** (what we port):

- URLs are built in
  [`store/globals.js`](../../store/globals.js) (`getLibraryItemCoverSrc`, line 30):
  `GET /api/items/:id/cover?ts=<updatedAt>[&raw=1][&token=<accessToken>]`. Author
  images use `GET /api/authors/:id/image?ts=<updatedAt>[&token=…]`
  ([`components/covers/AuthorImage.vue`](../../components/covers/AuthorImage.vue),
  lines 57–67). If `media.coverPath` is an absolute `http(s)` URL, it is used
  directly.
- Legacy adds `?token=` for servers older than 2.17
  ([`store/index.js`](../../store/index.js), `getDoesServerImagesRequireToken`, line
  95; also [`NowPlayingInfo.swift`](../../ios/App/Shared/util/NowPlayingInfo.swift),
  lines 19–36). That path is dead code below our 2.26.0 minimum and is not ported.
- The legacy app never sends `width`, so every cover is the server's default
  400 px rendition, whether it is shown in a 50 pt row or a full-width iPad grid.
  The player passes `raw` and gets the original file at full resolution
  ([`components/app/AudioPlayer.vue`](../../components/app/AudioPlayer.vue),
  line 47).
- Caching is left to the WebView. Native code (`ApiClient.getData`,
  [`ios/App/Shared/util/ApiClient.swift`](../../ios/App/Shared/util/ApiClient.swift),
  lines 14–19) decodes full-size `UIImage`s with no cache and no downsampling.
- Downloads fetch the cover as an extra part named `cover.jpg`
  ([`ios/App/App/plugins/AbsDownloader.swift`](../../ios/App/App/plugins/AbsDownloader.swift),
  lines 358–364 and 419–437). The URL is always `?token=<accessToken>`
  ([`DownloadItemPart.swift`](../../ios/App/Shared/models/download/DownloadItemPart.swift),
  line 81), so the token is persisted in the database. Since the server picks the
  format from `Accept`, `cover.jpg` may not actually be a JPEG. Offline items show
  the local file
  ([`BookCover.vue`](../../components/covers/BookCover.vue), `fullCoverUrl`, line
  112).
- Custom headers (`serverConfig.customHeaders`) are only sent by the connect form
  ([`components/connection/ServerConnectForm.vue`](../../components/connection/ServerConnectForm.vue),
  line 640). `<img>` cover requests can't carry them, so covers break behind
  header-gated reverse proxies.
- **Placeholders:**
  [`BookCover.vue`](../../components/covers/BookCover.vue) has three states:
  - no cover: title and author drawn on a placeholder (lines 25–32);
  - load error: logo on a tinted background (lines 18–23);
  - loaded: a 300 ms fade-in.

  When the image's aspect ratio differs from the library's by more than 0.15, it
  is shown aspect-fit over a blurred copy of itself (lines 152–171). The library
  aspect ratio is 1.6 or 1
  ([`store/libraries.js`](../../store/libraries.js), lines 27–30).
- **Average colour:** the player and item page tint their backgrounds with the
  cover's average colour and an `isLight` flag. This uses `fast-average-color`
  ([`utils/coverAverageColor.js`](../../utils/coverAverageColor.js)), with
  fallback `rgb(55, 56, 56)` (`AudioPlayer.vue`, lines 432–442).

**Server behaviour** (verified in
[advplyr/audiobookshelf@83dce68](https://github.com/advplyr/audiobookshelf/tree/83dce682e88c2b32b0c33a8f83a9457bfc459e0e),
release v2.37.2):

- `GET /api/items/:id/cover` reads `width`, `height`, `format`, `raw`, and `ts`
  ([`LibraryItemController.getCover`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/controllers/LibraryItemController.js#L401-L433)).
  - `raw` (any value) sends the original file.
  - Otherwise `width` and `height` are clamped to 1–4096. Width defaults to 400.
  - `format` must be `webp`, `jpeg`, or `png`. When it's absent, the server sends
    WebP if `Accept` contains `image/webp` or is exactly `*/*`, else JPEG
    ([`reqSupportsWebp`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/utils/index.js#L144-L147)).
  - Non-raw item ids must be UUIDs.
  - When `ts` is present, the response carries
    `Cache-Control: private, max-age=86400`.
- The server resizes with ffmpeg (`scale=W:-1`, which keeps the aspect ratio) and
  keeps one file per id, size, and format, named `<id>_<width>[x<height>].<format>`
  ([`CacheManager.handleCoverCache`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/managers/CacheManager.js#L43-L91)).
  Every distinct width a client asks for adds a file to the server's disk.
- `GET /api/authors/:id/image` takes the same parameters
  ([`AuthorController.getImage`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/controllers/AuthorController.js#L391-L419)).
- **Authentication:** since v2.17.0, `GET` on both image routes needs no
  authentication
  ([`Auth.ignorePatterns`, v2.17.0](https://github.com/advplyr/audiobookshelf/blob/v2.17.0/server/Auth.js#L21);
  [current](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/Auth.js#L21)).
  The minimum supported server is 2.26.0 ([0007](0007-streaming.md)), so image
  requests never need a token. The legacy pre-2.17 `?token=` rule is not ported.

**Platform** (verified in the Xcode 27.2 SDKs):

- **`AsyncImage` on OS 27:**
  - It gains `init(request: URLRequest?, …)` and the
    `asyncImageURLSession(_:)` modifier (`SwiftUI.swiftinterface`, iOS and macOS,
    `@available(anyAppleOS 27.0, *)`).
  - So the issue note "AsyncImage can't send custom headers" no longer holds at
    our minimum OS.
  - It still produces only a SwiftUI `Image`. It has no downsampling and no cache
    of its own beyond the session's `URLCache`.
- **Now Playing:** the NowPlaying framework provides
  `Artwork(id:artworkProvider: @Sendable (CGSize) async throws -> ArtworkRepresentation)`,
  and `ArtworkRepresentation` is built with `init(cgImage:)` or `init(data:)`.
  MediaPlayer is not used ([0006](0006-now-playing.md)).
- **CarPlay:**
  - `CPListItem` takes a `UIImage`, through `init(text:detailText:image:)` or
    `setImage(_:)`. The size limit is the runtime value
    `CPListItem.maximumImageSize`.
  - Other limits: `CPListImageRowItemElement.maximumImageSize`,
    `CPThumbnailImage.maximumImageSize(forAspectRatio:)` (iOS 27.0), and
    `CPNowPlayingButtonMaximumImageSize`.
  - Images should match `CPInterfaceController.carTraitCollection`'s display
    scale (`CPInterfaceController.h`, lines 177–180).
- **ImageIO:**
  - `CGImageSourceCreateThumbnailAtIndex` with
    `kCGImageSourceThumbnailMaxPixelSize`,
    `kCGImageSourceCreateThumbnailFromImageAlways`,
    `kCGImageSourceCreateThumbnailWithTransform`, and
    `kCGImageSourceShouldCacheImmediately` downsamples during decode.
  - The macOS 27.2 runtime lists `org.webmproject.webp` among
    `CGImageSourceCopyTypeIdentifiers()`.
- **Image types:** `CGImage` is `Sendable` under Swift 6. It turns into
  `Image(decorative:scale:orientation:)` and `UIImage(cgImage:scale:orientation:)`.
- **Display scale:** `UIScreen.main` is deprecated (iOS 26), so the scale has to
  come from the environment or trait collection.

## Decision drivers

1. **Correct auth on every supported server (2.26.0+):** per-server custom headers
   on every image request, never the Audiobookshelf token, and no credentials
   sent to third-party hosts, including through redirects.
2. **Bounded memory** with a 2,000-item library on the smallest iPhone, including
   fast scrolling.
3. **One image source for SwiftUI, CarPlay (`UIImage`), Now Playing (`CGImage`),
   and widgets.** CarPlay can run with no window scene.
4. **Offline:** downloaded items show covers with no network.
5. **Sharp images at the size shown,** without making the server keep a rendition
   for every possible width.
6. **Built-in frameworks only,** Swift 6 strict concurrency, and testable with
   `swift test` on macOS.

## Options considered

### Option 1: `AsyncImage(request:)` with a tuned `URLCache`

Views use the OS 27 `AsyncImage(request:)` with a per-server `URLRequest` carrying
the server's custom headers. `.asyncImageURLSession`
points at a session whose `URLCache` lives in the App Group container. Non-view
consumers (CarPlay, Now Playing, widgets) each fetch through the same session and
decode on their own.

- Pros:
  - Least code. Views get loading, failure, and transitions from `AsyncImagePhase`.
  - Custom headers now work (OS 27 API), so auth is no longer a blocker.
  - `URLCache` handles the disk.
- Cons:
  - **Full-size decode:**
    - `AsyncImage` decodes at the image's full pixel size and has no
      downsampling.
    - A 600 px-wide WebP shown in a 60 pt row still costs 600 × 960 × 4 B ≈ 2.2
      MiB.
    - There is no decoded-image cache, so cells re-decode every time they scroll
      back into view.
  - **No reusable bitmap:** it yields a SwiftUI `Image`, which CarPlay
    (`UIImage`), Now Playing (`CGImage`), and average-colour sampling can't use.
    That means a second loader anyway.
  - **No control over cancellation or deduplication:** two views showing the same
    cover start two loads.
  - **`URLCache` limits:**
    - Its policy follows the server's headers: one day with `ts`, and heuristic
      without it.
    - It is a database, not files, so it is opaque to widget extensions. Safe
      concurrent use across processes is undocumented.
    - It won't store responses larger than a fraction of its disk capacity.
    - We can't evict per server on logout.
  - **No offline lookup:** it has no hook to prefer a downloaded cover file over
    the network.

### Option 2: Custom `ImagePipeline` actor on URLSession and ImageIO (chosen)

The `ImagePipeline` actor does the following:

- deduplicates in-flight loads;
- fetches with a dedicated `URLSession`;
- writes the encoded bytes to a file cache in the App Group container;
- downsamples with ImageIO to the exact pixel size requested;
- keeps decoded `CGImage`s in a cost-bounded in-memory LRU cache.

A thin SwiftUI `CoverView` in `ABSUI` and adapters for CarPlay and Now
Playing all call the pipeline.

- Pros:
  - **Memory follows display size, not source size.** Decoded bitmaps are bounded
    by a byte budget.
  - **One decoded `CGImage` serves every consumer,** with no format conversion.
  - **Cache keys are ours** (server, entity, `updatedAt`, size), so cached files
    never go stale. Nothing has to be revalidated, and a logout can delete one
    server's folder.
  - **Offline-first lookup is natural:** memory, then the downloaded cover file,
    then the disk cache, then the network.
  - **Widgets can read the same files.**
  - **Deterministic tests:**
    - `URLProtocol` stubs for the network;
    - fixture images for the decoder;
    - an injected clock and directory for the file cache.
- Cons:
  - **More code to own:** about 400–600 lines for the actor, file store, LRU, and
    view.
  - **Some reinvention:** it reimplements part of what `AsyncImage` does (phases
    and transitions).
  - **Two stores to keep consistent:** the file cache and the downloaded covers.

### Option 3: Third-party pipeline (Nuke, Kingfisher, SDWebImage)

- Pros:
  - Mature deduplication, downsampling, prefetching, and disk caching.
- Cons:
  - Breaks the "built-in frameworks first, no third-party image libraries" rule.
  - We would still write the auth, offline, and CarPlay adapters.
  - Its update and Swift 6 strict-concurrency schedule is someone else's.

## Decision

Use **Option 2**. Don't use `AsyncImage` for server images. It remains fine for
static, unauthenticated remote images (none are planned).

**Placement** (no new module or dependency edge, per [0001](0001-architecture.md)):

- `ABSCore`:
  - the `ImagePipeline` actor;
  - the `ImageKey`, `ImageVariant`, and `ImageSource` types;
  - the `CoverFileStore`;
  - the `ImageRequestBuilding` protocol, which maps an `ImageSource` to a
    `URLRequest`;
  - the `DownloadedCoverLookup` protocol, which returns the local cover file
    URL and its `updatedAt` for an `ImageKey`, or `nil`.
- `ABSAPI` implements `ImageRequestBuilding` in `MediaURLBuilder`, per server:
  base URL including any sub-path, and custom headers.
- `ABSAppModel` implements `DownloadedCoverLookup` over ABSData's
  `LocalItemStore`: the downloaded item's cover relative path, resolved against
  the downloads folder, and `LocalLibraryItem.coverUpdatedAt`. The pipeline
  never imports `ABSDownloads` or `ABSData`.
- `ABSUI` provides `CoverView`, `AuthorImageView`, `GroupCoverView`,
  `CoverPlaceholder`, and `CoverPalette`. It receives the pipeline through the
  SwiftUI environment. Issue #43 (P3-03) lists `ABSUI/Images/ImagePipeline.swift`;
  per the module decision the actor lives in `ABSCore`, and only the views are in
  `ABSUI`.
- `ABSPlayback`, `ABSDownloads`, and the CarPlay code in the app target call the
  pipeline (`cgImage(for:size:)`) directly.
- `AppEnvironment` creates the pipeline once per process, outside any scene, and
  injects the `ABSAPI` builder and the `ABSAppModel` lookup.

**Requests:**

- **Covers:**
  `GET {server}/api/items/{id}/cover?width={W}&format=webp&ts={updatedAtMs}`.
- **Author images:** `GET {server}/api/authors/{id}/image?…`, with the same
  parameters.
- **Width buckets:** `W` is one of three fixed buckets: **300, 600, or 1200 px**.
  Pick the smallest bucket that is at least the displayed width × display scale;
  anything over 1200 px uses 1200. Fixed buckets keep the number of server-side
  renditions at three per item.
- **WebP:** `format=webp` is sent explicitly, so the response doesn't depend on
  `URLSession`'s `Accept` header. It is also smaller than JPEG.
- **`ts`:** sending `ts` matches the legacy app, busts any proxy cache, and gets
  the server's `Cache-Control`.
- **Auth:** there are two kinds of header, and they are treated differently.
  - The **Audiobookshelf bearer token** (the access token `ABSAPI` adds to API
    calls) is never added to image requests. There is no `?token=` and no token
    refresh either: both image routes are unauthenticated on every supported
    server (2.26.0+).
  - **User-configured custom headers** for the server (from the Keychain) are
    always sent to the server's origin, whatever their name. That includes a
    proxy credential such as `Authorization: Basic …`. The builder only
    guarantees that it never adds the Audiobookshelf bearer itself.
  - A 401 or 403 means a proxy rejected the request (wrong custom headers). The
    pipeline shows the placeholder and does not retry in a loop.
- **Custom headers:** they are applied per request, not through
  `httpAdditionalHeaders`, because one session serves several servers.
- **Absolute `coverPath` URLs** (legacy external covers) are fetched without
  custom headers, so credentials never leave the server's origin.
- **Redirects:** the image session's delegate implements
  `urlSession(_:task:willPerformHTTPRedirection:newRequest:)`, because
  `URLSession` would otherwise carry the custom headers to the new location.
  - A redirect to the same origin (same host and port, or the same host
    upgraded from `http` to `https` on default ports) is followed with the
    headers unchanged.
  - A redirect to any other origin is followed only after the new request is
    rebuilt from the URL alone: every custom header (and any `Authorization`
    or `Cookie` header) is stripped, and `Accept` is set again. If it can't be
    rebuilt, the redirect is refused and the placeholder is shown.
  - The same check runs for every hop, so a chain can't return to a
    credentialed state after leaving the origin.
- **Session:** a dedicated `URLSession` with `urlCache = nil` and
  `requestCachePolicy = .reloadIgnoringLocalCacheData`. Our own file cache is
  authoritative, and versioned keys never need revalidation. The default
  per-host connection limit applies.

**Keys and cache layers:**

- **Keys:**
  - `ImageKey` is (server connection ID, kind (`itemCover` or `authorImage`),
    entity ID, `updatedAt`, variant).
  - The memory key adds the decoded max pixel size, rounded up to a multiple of
    32 px.
  - The server connection ID is the stable local UUID, not the address, so it
    survives an address change.
  - A changed `updatedAt` (from a fetch or a socket event) produces a new key. Old
    entries simply age out.
- **Load order:**
  1. memory LRU;
  2. downloaded cover file, from the injected `DownloadedCoverLookup`. It is used
     when the item is downloaded and its `coverUpdatedAt` is not older than the
     key's `updatedAt`. Offline, it is used whatever its age;
  3. `CoverFileStore`;
  4. network.

  Steps 2–4 decode off the actor in a `@concurrent` function. Concurrent decodes
  are capped at 4 on iPhone and at the active processor count on iPad and Mac
  (see the memory budget below).
- **Deduplication and cancellation:**
  - In-flight work is a `[ImageKey: Task]` entry with a waiter count.
  - When the last waiter cancels (a cell scrolls away), the network task is
    cancelled.
- **Decoding:**
  - Use `CGImageSourceCreateWithData` (or `…WithURL` for files) with
    `kCGImageSourceShouldCache: false`.
  - Then call `CGImageSourceCreateThumbnailAtIndex` with
    `kCGImageSourceThumbnailMaxPixelSize`,
    `kCGImageSourceCreateThumbnailFromImageAlways`,
    `kCGImageSourceCreateThumbnailWithTransform`, and
    `kCGImageSourceShouldCacheImmediately` all set.
  - The result is a fully decoded `CGImage`, already oriented `.up`.
- **`CoverFileStore`:**
  - **Location:** the store lives in the App Group container so the widget
    extension can read it (P5-11b, #89). Files are at
    `<container for group.org.davidjensenius.Audiobookshelf>/Library/Caches/Images/<serverID>/<kind>-<entityID>-<updatedAt>-<bucket>.<webp|jpg>`
    (`.jpg` when the file was materialised from a downloaded cover).
    Entity IDs are sanitised before use in file names.
  - **Fallback:** if the App Group entitlement is missing (unsigned CI builds,
    for example), the store uses the app's own `Caches` directory. Widgets then
    show placeholders.
  - **Writers:** only the app process writes and evicts. Extensions only read.
  - **Eviction:** LRU by file modification date, which is touched on hits at most
    once per day. Eviction runs at launch and when the app enters the background.
  - **Logout:** removing a server deletes its folder.
- **Rendering:** the pipeline returns `CGImage` plus scale. Each consumer wraps
  it:
  - SwiftUI: `Image(decorative:scale:)`;
  - CarPlay: `UIImage(cgImage:scale:orientation:)`;
  - NowPlaying framework: `ArtworkRepresentation(cgImage:)`.

  Views read the scale from `@Environment(\.displayScale)`, and CarPlay from
  `carTraitCollection.displayScale`.

**Consumers:**

- **CarPlay:**
  - Request size = `CPListItem.maximumImageSize` (or the relevant element's or
    `CPThumbnailImage`'s maximum) × `carTraitCollection.displayScale`, which
    fetches the 300 bucket.
  - Show lists immediately with a bundled placeholder, then call `setImage(_:)` as
    each cover arrives.
  - Only load covers for the items in the template; car lists may be trimmed to
    about 12.
- **Now Playing:**
  - The current item's artwork is decoded from the 1200 bucket (or the downloaded
    file) and is **pinned**: kept outside the LRU until playback changes.
  - The NowPlaying `Artwork` provider (in `ABSPlayback/NowPlaying/`) downsamples
    the pinned image to the size the system asks for. It returns
    `ArtworkRepresentation(cgImage:)`. MediaPlayer is not used
    ([0006](0006-now-playing.md)).
- **Offline covers:**
  - `ABSDownloads` downloads the cover with
    `width=1200&format=jpeg&ts=…`. Like other image requests, it sends the
    user-configured custom headers but not the Audiobookshelf bearer token, and
    it applies the same redirect policy.
  - It stores the result as `cover.jpg` in the item's download folder, which is
    not a cache directory. It records the relative path and
    `LocalLibraryItem.coverUpdatedAt` in ABSData, which is what
    `DownloadedCoverLookup` reads.
  - JPEG keeps exported or shared files portable. 1200 px is enough for the player
    on every device we target.
  - If a later fetch shows a newer `updatedAt`, the cover is refreshed in the
    background.
  - Offline, the pipeline always takes the downloaded file over the network.
- **Widgets** (P5-11b, #89):
  - `WidgetSnapshotWriter` records each snapshot item's `ImageKey` (300 bucket).
  - Before reloading timelines it calls
    `ImagePipeline.ensureCoverFile(for: ImageKey) async throws -> URL` for each
    of those keys. A normal `cgImage(for:size:)` call isn't enough, because it
    can return early from the memory LRU or the downloaded cover without ever
    writing `CoverFileStore`.
  - `ensureCoverFile` skips the memory LRU and guarantees a file for that exact
    key:
    1. if `CoverFileStore` already has the file, it returns it;
    2. if `DownloadedCoverLookup` has a usable downloaded cover, it downsamples
       it to the bucket and writes it to `CoverFileStore` as JPEG with
       `CGImageDestinationCreateWithURL`;
    3. otherwise it fetches the bucket from the network and writes it.
  - Readers find the file by key whatever its extension (`.webp` or `.jpg`);
    ImageIO detects the format from the bytes.
  - The widget reads covers through the pipeline's App Group cover cache by
    `ImageKey`. It uses a read-only, cache-only pipeline: no request builder,
    no memory LRU. It downsamples to the widget's size.
  - It never touches the network, which widgets can't rely on.
  - On a miss it shows the placeholder, and the app fills the file on its next
    run.
  - Files for snapshot items are exempt from LRU eviction while they are in the
    current snapshot.
- **Placeholders and palette:**
  - Port the legacy states: a generated title and author placeholder when there
    is no cover, a logo placeholder on failure, and a 0.3 s fade-in.
  - When the aspect ratio differs from the library's (1.6 or 1) by more than
    0.15, show the image aspect-fit over a blurred fill of itself.
  - `CoverPalette` computes the average colour with `CIAreaAverage` on the
    300-bucket image. It caches the colour per `ImageKey` (variant excluded) and
    derives `isLight` from relative luminance. The fallback is `rgb(55, 56, 56)`,
    as in the legacy app.

**Cache sizes** (initial values, tuned after the validation spike):

| Layer | iPhone | iPad | Mac | Widget extension |
| --- | --- | --- | --- | --- |
| Decoded memory LRU (cost = width × height × 4 B) | 64 MiB | 128 MiB | 256 MiB | none (decode on demand) |
| Pinned Now Playing artwork | ≤ 1 image, ≤ 5.5 MiB (1200²×4) | same | same | — |
| `CoverFileStore` (encoded, purgeable) | 256 MiB | 256 MiB | 512 MiB | read-only |
| Downloaded covers | Not counted; deleted with the download | | | |
| `URLCache` | Disabled for the image session | | | |

**Memory budget for a 2,000-item library:**

| Scenario | Decoded size per image | All 2,000 decoded | What we hold |
| --- | --- | --- | --- |
| iPhone 2-column grid (≈170 pt @3x → 510 × 816 px) | 1.59 MiB | 3.1 GiB, impossible | ≈ 40 images in 64 MiB, about 4 screens |
| iPad/Mac grid (≈160 pt @2x → 320 × 512 px) | 0.63 MiB | 1.2 GiB | ≈ 200 images in 128 MiB (iPad) or ≈ 400 in 256 MiB (Mac) |
| List row or CarPlay (≈60 pt @3x → 180 × 288 px) | 0.20 MiB | 400 MiB | ≈ 320 rows in 64 MiB |
| Player / Now Playing (1200 × 1200 px) | 5.5 MiB | n/a | 1 pinned |

Retained and peak memory are budgeted separately on iPhone:

- **Retained** (what stays after loads settle): the 64 MiB LRU plus the
  5.5 MiB pinned artwork, so **≤ 70 MiB**.
- **Transient** (live only while decoding): concurrent decodes are capped at
  **4 on iPhone** (the processor count on iPad and Mac). Four grid decodes of
  510 × 816 px are ≈ 6.4 MiB of output buffers. Allow the same again for
  encoded data and ImageIO scratch space, so ≈ **13 MiB**. If a Now Playing
  decode of the 1200 bucket (5.5 MiB) takes one of the slots, the output
  buffers are ≈ 10.3 MiB, still inside that allowance.
- **Peak** = retained + transient, so **≤ 83 MiB** on iPhone.

The iPad and Mac peaks are their LRU size + 5.5 MiB + their transient
allowance, with the same rule.

Disk for 2,000 items, assuming the sizes the spike will confirm (300 px WebP
≈ 15 KB, 600 px ≈ 45 KB, 1200 px ≈ 150 KB):

- the 300 and 600 buckets for every item: ≈ 120 MB;
- the 1200 bucket for about 50 recently played items: ≈ 7.5 MB.

That fits under 256 MiB without eviction churn.

**Memory pressure:**

- iOS:
  - On `UIApplication.didReceiveMemoryWarningNotification`, empty the LRU,
    keeping only the pinned artwork.
  - On entering the background, trim the LRU to 25 %.
- macOS: listen to `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`.
  - `.warning` trims to 50 %.
  - `.critical` empties the LRU.

## Consequences

- **Single image path:** every image goes through `ImagePipeline`. A
  contributor-facing rule is to not call `AsyncImage`, `UIImage(data:)`, or
  `NSImage(contentsOf:)` for server images.
- **Building blocks:**
  - `ABSCore` gains `DownloadedCoverLookup`.
  - `ABSUI` gains `CoverView`, `AuthorImageView`, `GroupCoverView`,
    `CoverPlaceholder`, and `CoverPalette`.
  - `ABSAPI` gains `MediaURLBuilder: ImageRequestBuilding`.
  - `ABSAppModel` gains the `LocalItemStore`-backed lookup.
  - ABSData's `LocalLibraryItem` gains `coverUpdatedAt: Date?` (ADR 0003).
  - None of this needs a new module dependency. `ImagePipeline` depends on
    neither `ABSDownloads` nor `ABSData`.
- **Auth:** image requests never carry the Audiobookshelf token, so none end up
  in URLs, logs, the database, or cached files. User-configured custom headers
  (including proxy `Authorization: Basic …`) go to the server origin only and
  are stripped on cross-origin redirects. Proxies that require custom headers
  work for images too, which fixes a legacy gap.
- **Server disk:** the server keeps at most three cover renditions per item for
  this app, plus the 1200 px JPEG for downloaded items.
- **Follow-ups:**
  - the pipeline and views in #43 (P3-03);
  - the offline cover (`width=1200&format=jpeg`) in #73 (P4-02);
  - CarPlay list images in #80 (P5-03);
  - the widget snapshot and cover read in #89 (P5-11b);
  - the Now Playing artwork provider in `ABSPlayback/NowPlaying/`
    ([0006](0006-now-playing.md)).
  - The App Group is `group.org.davidjensenius.Audiobookshelf` (#18, P0-03).
    Each target that reads the cover cache needs the entitlement.
- **Harder:**
  - We own cancellation, eviction, and cross-process file access.
  - Format support depends on ImageIO, so a server returning an exotic format via
    `raw` won't decode. `raw` is not used.

## Validation

- **Unit tests** (Swift Testing, `ABSCoreTests` and `ABSAPITests`; in #43):
  - request building: user-configured custom headers present (including a
    user-configured `Authorization: Basic …`), the Audiobookshelf bearer token
    never present, no `token` query item, and no headers for absolute external
    URLs;
  - redirects (through a `URLProtocol` stub): a same-origin redirect keeps the
    custom headers; a cross-origin redirect arrives with no custom,
    `Authorization`, or `Cookie` headers, and this holds for a later hop back
    to the server origin as well;
  - `ensureCoverFile(for:)`: after a memory hit and after a downloaded-cover
    hit, the file for that exact `ImageKey` exists in `CoverFileStore`;
  - bucket selection;
  - key and file-path construction;
  - deduplication: two concurrent loads produce one `URLProtocol` hit;
  - cancellation when the last waiter leaves;
  - LRU cost accounting and trimming on a simulated memory warning;
  - the order downloaded file (through a fake `DownloadedCoverLookup`, including
    a stale `coverUpdatedAt`) → file store → network;
  - downsampling a fixture JPEG and WebP to a requested max pixel size.
- **Memory spike** (performed in #43, P3-03, as an acceptance criterion):
  - Scroll a large library against a real server on the smallest supported
    iPhone and on an iPad.
  - Record Instruments Allocations and the VM tracker. Pass: retained image
    memory after scrolling stops stays within the retained budget (≤ 70 MiB on
    iPhone), peak image memory while flinging stays within the peak budget
    (≤ 83 MiB on iPhone), and there are no hitches beyond one frame. If peak
    goes over, lower the decode cap before the LRU size.
  - Record real encoded sizes per bucket and adjust the disk numbers in a
    follow-up.
- **CarPlay** (performed in #80, P5-03): a manual check on a device (the
  Simulator isn't supported for CarPlay in the Xcode 27.2 Device Hub) that list
  images appear and are sharp.
- **Review check:** reviewers reject new `AsyncImage` or ad-hoc image loading for
  server images.

## References

- **Research:**
  - [Legacy API inventory](../research/legacy-api-inventory.md) (the cover route
    and version gates);
  - [platform API research](../research/platform-apis.md), §2 on CarPlay limits
    and image sizes.
- **ADRs:**
  - [0001 Architecture](0001-architecture.md);
  - [0003 SwiftData](0003-swiftdata.md) (`LocalLibraryItem.coverUpdatedAt`, App
    Group);
  - [0006 Now Playing](0006-now-playing.md);
  - [0007 Streaming and minimum server version](0007-streaming.md);
  - [architecture.md](../architecture.md).
- **Legacy code:**
  - [`components/covers/BookCover.vue`](../../components/covers/BookCover.vue),
    [`components/covers/AuthorImage.vue`](../../components/covers/AuthorImage.vue);
  - [`store/globals.js`](../../store/globals.js),
    [`store/index.js`](../../store/index.js),
    [`store/libraries.js`](../../store/libraries.js);
  - [`utils/coverAverageColor.js`](../../utils/coverAverageColor.js);
  - [`ios/App/Shared/util/NowPlayingInfo.swift`](../../ios/App/Shared/util/NowPlayingInfo.swift),
    [`ios/App/Shared/util/ApiClient.swift`](../../ios/App/Shared/util/ApiClient.swift),
    [`ios/App/App/plugins/AbsDownloader.swift`](../../ios/App/App/plugins/AbsDownloader.swift),
    [`ios/App/Shared/models/download/DownloadItemPart.swift`](../../ios/App/Shared/models/download/DownloadItemPart.swift).
- **Server** (read-only):
  - [`LibraryItemController.getCover`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/controllers/LibraryItemController.js#L401-L433);
  - [`CacheManager`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/managers/CacheManager.js#L10-L91);
  - [`AuthorController.getImage`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/controllers/AuthorController.js#L391-L419);
  - [`Auth.js` (current)](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/Auth.js#L21-L38),
    [v2.17.0](https://github.com/advplyr/audiobookshelf/blob/v2.17.0/server/Auth.js#L21);
  - [`resizeImage`](https://github.com/advplyr/audiobookshelf/blob/83dce682e88c2b32b0c33a8f83a9457bfc459e0e/server/utils/ffmpegHelpers.js#L78-L98).
- **SDK headers and interfaces** (Xcode 27.2):
  - `SwiftUI.swiftinterface` (`AsyncImage.init(request:…)`,
    `asyncImageURLSession(_:)`);
  - `SwiftUICore.swiftinterface` (`Image(decorative:scale:orientation:)`);
  - `ImageIO/CGImageSource.h`;
  - `CarPlay/CPListItem.h`, `CPListImageRowItemElement.h`, `CPThumbnailImage.h`,
    `CPNowPlayingButton.h`, `CPInterfaceController.h`;
  - `NowPlaying.swiftinterface` (`Artwork`, `ArtworkRepresentation`).
- **Apple documentation:**
  - [Image I/O](https://developer.apple.com/documentation/imageio);
  - [`CGImageSourceCreateThumbnailAtIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:));
  - [`AsyncImage`](https://developer.apple.com/documentation/swiftui/asyncimage);
  - [`CPListItem`](https://developer.apple.com/documentation/carplay/cplistitem);
  - [`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)).
