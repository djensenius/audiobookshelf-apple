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
    always sent to the server's origin. They can never be named
    `Authorization` or `Cookie`: the API client rejects those names when the
    server is configured, because API requests need `Authorization` for the
    bearer token and a proxy header there would be overwritten. A proxy that
    needs credentials must use a non-`Authorization` header or a service token,
    for example Cloudflare Access's `CF-Access-Client-Id` and
    `CF-Access-Client-Secret`. The image request builder never adds the
    Audiobookshelf bearer itself.
  - A 401 or 403 means a proxy rejected the request (wrong custom headers). The
    pipeline shows the placeholder and does not retry in a loop.
- **Custom headers:** they are applied per request, not through
  `httpAdditionalHeaders`, because one session serves several servers.
- **Absolute `coverPath` URLs** (legacy external covers) are fetched without
  custom headers, so credentials never leave the server's origin.
- **Redirects:** the image session's delegate implements
  `urlSession(_:task:willPerformHTTPRedirection:newRequest:)`, because
  `URLSession` would otherwise carry the custom headers to the new location.
  - **Origin** means scheme + host + effective port (the explicit port, or 80
    for `http` and 443 for `https`).
  - A redirect to the same origin is followed with the headers unchanged.
  - The only other case that keeps the headers is an upgrade from `http` to
    `https` on the same host, where both URLs use the default port (80 → 443).
  - A downgrade (`https` → `http`, on any host or port, for example
    `https://books.example:8443` → `http://books.example:8443`) is refused:
    the delegate returns `nil` and the placeholder is shown.
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
- **No cookies:** header stripping isn't enough, because cookies are not scoped
  by port and the cookie store would add them to, for example, a redirect from
  `https://books.example` to `https://books.example:8443`. So the image session
  configuration sets `httpCookieStorage = nil`, `httpShouldSetCookies = false`,
  and `httpCookieAcceptPolicy = .never`. Every image request, including each
  rebuilt redirect request, also sets `httpShouldHandleCookies = false`.

**Keys and cache layers:**

- **Keys:**
  - `ImageKey` is (server connection ID, kind (`itemCover` or `authorImage`),
    entity ID, `updatedAt`, variant).
  - The memory key adds the decoded **pixel box** (the width and height the
    view needs, in pixels). Each side is rounded up to a multiple of 32 px and
    capped at 1200 px.
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
  are capped at 4 on iPhone and at the active processor count on iPad and Mac.
  At most one of them may hold the **large-decode slot**, which any decode whose
  pixel box is larger than 512 × 832 px in area (for example the 1200 × 1200
  player box), any normalizing decode (see Decoding), and the Now Playing
  provider's downsampling must take (see the memory budget below).
- **Stale offline fallback:** when step 2 uses a downloaded cover whose
  `coverUpdatedAt` is older than the requested key's `updatedAt` (offline only),
  the image is shown but is **not** stored in the memory LRU under the requested
  key. It is cached under the fallback's own version key (the same key with
  `updatedAt` = `coverUpdatedAt`), which step 2 checks before decoding the file
  again. Nothing is written to `CoverFileStore`. Once the device is back
  online, a load of the requested key misses the LRU, skips the stale file, and
  fetches the new cover.
- **Deduplication and cancellation** (two levels, so views that need the same
  bucket at different pixel sizes share bytes but not a decode):
  - **Fetch:** getting the encoded bytes for steps 2–4 (downloaded file,
    `CoverFileStore`, or network) is a `[ImageKey: Task]` entry. There is at
    most one fetch per `ImageKey`. Its result records the version it actually
    holds, which the stale-fallback rule above uses. The bytes are released
    once no decode is waiting on them.
  - **Decode:** decoding is a `[MemoryKey: Task]` entry, where the memory key is
    `ImageKey` + rounded pixel box. Each decode waits on the fetch for its
    `ImageKey`, so decodes of different boxes share one fetch's bytes. Views
    asking for the same memory key share one decode.
  - **Cancellation:** a decode is cancelled when its last view waiter leaves
    (a cell scrolls away). A fetch is cancelled when no decode is waiting on it,
    which cancels its network task.
- **Decoding:**
  - Use `CGImageSourceCreateWithData` (or `…WithURL` for files) with
    `kCGImageSourceShouldCache: false`.
  - Read `CGImageSourceCopyPropertiesAtIndex` first (pixel width and height,
    orientation, `kCGImagePropertyDepth`, `kCGImagePropertyColorModel`,
    `kCGImagePropertyIsFloat`).
  - **Fit the box:** set `kCGImageSourceThumbnailMaxPixelSize` to the long side
    of the source aspect-fitted into the pixel box. The max pixel size only
    bounds the long side, so passing the box's long side would decode a square
    cover in an iPhone grid box (512 × 832) at 832 × 832 (2.64 MiB) instead of
    within 512 × 832 (≤ 1.625 MiB).
  - Then call `CGImageSourceCreateThumbnailAtIndex` with that size,
    `kCGImageSourceCreateThumbnailFromImageAlways`,
    `kCGImageSourceCreateThumbnailWithTransform`, and
    `kCGImageSourceShouldCacheImmediately` all set.
  - **Normalize:** ImageIO keeps the source's pixel format, so a 16-bit PNG
    decodes at 8 B/px, and a format Core Animation can't display directly can
    make it keep a second copy. If the result has `bitsPerComponent > 8`, or
    isn't 8-bit premultiplied RGBA/BGRA (or the 8-bit RGB "skip" equivalents),
    redraw it into an 8-bit premultiplied `CGContext` before caching. The
    context uses Display P3 when the source colour space is wide gamut
    (`CGColorSpaceIsWideGamutRGB`), and sRGB otherwise. The 8 B/px intermediate
    is freed straight afterwards.
  - Sources with float samples or more than 16 bits per component are
    rejected and show the placeholder, so no intermediate is ever above
    8 B/px. Only absolute external cover URLs can produce them: the server
    returns WebP and downloads are JPEG.
  - A decode whose properties show depth > 8 or a non-RGB colour model must
    hold the single **large-decode slot** (see the memory budget). If an image
    only turns out to need normalizing after decoding, the decode waits for
    that slot before redrawing.
  - The result is a fully decoded 8-bit `CGImage`, already oriented `.up`.
  - **LRU cost** is the image's real `bytesPerRow × height`, not a computed
    width × height × 4.
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
    once per day. Files for the current widget snapshot are skipped (see
    Widgets).
    - **Caps:** 256 MiB on iPhone and iPad, 512 MiB on Mac (also in the cache
      sizes table).
    - **Full passes** run at launch and when the app enters the background.
      Each pass enumerates the folder and resets the size counter from what it
      finds, which also picks up files the OS purged.
    - **During a session:** the store keeps its total size in bytes in memory.
      It is scanned at launch (`totalFileAllocatedSizeKey`) and updated on
      every write and delete. When a write pushes the total over the cap, the
      store starts one eviction task at `.background` priority, unless one is
      already running. The task deletes the oldest files until the total is at
      most 90 % of the cap. This bounds a Mac app left in the foreground for
      days.
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
    file) into a 1200 × 1200 px box, so it is at most 1200 × 1200 px whatever
    the cover's aspect ratio, and is **pinned**: kept outside the LRU until
    playback changes.
  - The NowPlaying `Artwork` provider (in `ABSPlayback/NowPlaying/`) downsamples
    the pinned image to the size the system asks for, in the large-decode slot.
    It returns `ArtworkRepresentation(cgImage:)`. MediaPlayer is not used
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
    key, holding the cover the key names:
    1. if `CoverFileStore` already has the file, it returns it;
    2. if `DownloadedCoverLookup` has a downloaded cover whose
       `LocalLibraryItem.coverUpdatedAt` is the same as or newer than the key's
       `updatedAt`, it downsamples it to the bucket and writes it to
       `CoverFileStore` as JPEG with `CGImageDestinationCreateWithURL`. This is
       stricter than the display load order: the offline "whatever its age"
       rule never applies here, so an older cover is never stored under a
       newer key (snapshot files are exempt from eviction and would keep it);
    3. otherwise it fetches the bucket from the network and writes it;
    4. if it is offline (or the fetch fails), it throws and writes nothing. The
       widget shows the placeholder for that item until a later snapshot
       succeeds.
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
| Decoded memory LRU (cost = `bytesPerRow × height`) | 64 MiB | 128 MiB | 256 MiB | none (decode on demand) |
| Pinned Now Playing artwork | ≤ 1 image, ≤ 5.49 MiB (1200 × 1200 box × 4 B) | same | same | — |
| `CoverFileStore` (encoded, purgeable) | 256 MiB | 256 MiB | 512 MiB | read-only |
| Downloaded covers | Not counted; deleted with the download | | | |
| `URLCache` | Disabled for the image session | | | |

**Memory budget for a 2,000-item library:**

| Scenario | Decoded size per image | All 2,000 decoded | What we hold |
| --- | --- | --- | --- |
| iPhone 2-column grid (≈170 pt @3x → 510 × 816 px, rounded box 512 × 832) | 1.625 MiB | 3.2 GiB, impossible | ≈ 39 images in 64 MiB, about 4 screens |
| iPad/Mac grid (≈160 pt @2x → 320 × 512 px) | 0.63 MiB | 1.2 GiB | ≈ 200 images in 128 MiB (iPad) or ≈ 400 in 256 MiB (Mac) |
| List row or CarPlay (≈60 pt @3x → 180 × 288 px, rounded box 192 × 288) | 0.21 MiB | 422 MiB | ≈ 300 rows in 64 MiB |
| Player / Now Playing (1200 × 1200 px box) | 5.49 MiB | n/a | 1 pinned |

Retained and peak memory are budgeted separately on iPhone. All sizes are
exact: grid image 512 × 832 × 4 B = 1.625 MiB, player image 1200 × 1200 × 4 B =
5.49 MiB, and its 16-bit intermediate 1200 × 1200 × 8 B = 10.99 MiB.

- **Retained** (what stays after loads settle): the 64 MiB LRU plus the
  5.49 MiB pinned artwork = 69.49 MiB, so **≤ 70 MiB**. The LRU charges real
  `bytesPerRow × height` and evicts before inserting, so it never goes over
  64 MiB, even for a moment.
- **Transient** (live only while decoding): concurrent decodes are capped at
  **4 on iPhone** (the processor count on iPad and Mac), and at most **one** of
  them holds the large-decode slot.
  - An ordinary decode (box ≤ 512 × 832 px, already 8-bit) is budgeted at 2×
    its output: 1.625 MiB output plus an equal allowance for encoded input and
    ImageIO scratch space = **3.25 MiB**.
  - The large-decode slot is budgeted for its worst case, a normalizing decode
    in the player box: 10.99 MiB intermediate + 5.49 MiB output + 5.49 MiB for
    encoded input and scratch = **21.97 MiB**. A non-normalizing player decode
    needs 5.49 + 5.49 = 10.99 MiB, and a normalizing grid decode needs
    3.25 + 1.625 + 1.625 = 6.5 MiB, so both fit.
  - Worst case: three ordinary decodes plus the large slot =
    3 × 3.25 + 21.97 = **31.72 MiB**.
- **Peak** = retained + transient = 69.49 + 31.72 = 101.22 MiB. Row padding in
  `bytesPerRow` (at most 64 B per row) adds under 0.35 MiB for the images live
  outside the LRU, so the budget is **≤ 102 MiB** on iPhone. While a new player
  image is being decoded, the old pinned image is still counted in retained;
  it is released only after the swap, so this sum already covers the overlap.

The iPad and Mac peaks follow the same rule: LRU size + 5.49 MiB pinned +
(processor count − 1) × 2 × their largest grid-box output + 21.97 MiB for the
large-decode slot.

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
  (never `Authorization` or `Cookie`; proxies use headers such as
  `CF-Access-Client-Id`/`CF-Access-Client-Secret` or a service token) go to
  the server origin only, are stripped on cross-origin redirects, and are never
  sent over an `https` → `http` downgrade. Proxies that require custom headers
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
  - request building: user-configured custom headers present (for example
    `CF-Access-Client-Id` and `CF-Access-Client-Secret`), no `Authorization`
    header (the Audiobookshelf bearer is never added, and custom headers can't
    use that name), no `token` query item, and no headers for absolute
    external URLs;
  - redirects (through a `URLProtocol` stub):
    - a same-origin redirect keeps the custom headers;
    - an `http` → `https` upgrade on the same host with default ports keeps
      them;
    - a same-host change of port, or of scheme on a non-default port, is
      treated as cross-origin;
    - an `https` → `http` downgrade (for example
      `https://books.example:8443` → `http://books.example:8443`) is refused;
    - a cross-origin redirect arrives with no custom, `Authorization`, or
      `Cookie` headers, and this holds for a later hop back to the server
      origin as well;
    - with a cookie stored for the server's host in `HTTPCookieStorage.shared`,
      no request or redirect hop (including `https://books.example` →
      `https://books.example:8443`) carries a `Cookie` header, a `Set-Cookie`
      response stores nothing, and every request has
      `httpShouldHandleCookies == false`;
  - stale offline fallback, offline then online: with a downloaded v1 cover
    and a key naming v2, the offline load shows v1 and leaves no LRU entry or
    file under the v2 key; after going online, the next v2 load makes one
    network request and returns v2;
  - `ensureCoverFile(for:)`:
    - after a memory hit and after a downloaded-cover hit, the file for that
      exact `ImageKey` exists in `CoverFileStore`;
    - with a downloaded cover older than the key's `updatedAt`, it fetches from
      the network instead, and offline it throws and writes no file;
  - bucket selection;
  - key and file-path construction, including pixel-box rounding to 32 px
    capped at 1200;
  - deduplication: two concurrent loads of the same memory key produce one
    `URLProtocol` hit and one decode. Two concurrent loads of the same
    `ImageKey` at different pixel boxes (for example a grid cell and a list row
    on the 600 bucket) produce one fetch and two decodes, each at its own size;
  - cancellation: a decode is cancelled when its last waiter leaves; the fetch
    keeps running while another decode still waits on it and is cancelled
    (with its network task) when none does;
  - LRU cost accounting (`bytesPerRow × height` of the real image), evicting
    before insert, and trimming on a simulated memory warning;
  - `CoverFileStore` size tracking: writes that push the total over a small
    test cap start exactly one background eviction, which brings the total to
    at most 90 % of the cap and skips current widget-snapshot files;
  - the order downloaded file (through a fake `DownloadedCoverLookup`, including
    a stale `coverUpdatedAt`) → file store → network;
  - downsampling a fixture JPEG and WebP to a requested pixel box, including a
    square cover in a 512 × 832 box, which decodes to at most 512 × 512;
  - normalizing a 16-bit PNG fixture and a Display P3 16-bit fixture to 8-bit
    premultiplied (sRGB and Display P3 respectively), and rejecting a float
    fixture;
  - the large-decode slot: a second large or normalizing decode waits until the
    first finishes.
- **Memory spike** (performed in #43, P3-03, as an acceptance criterion):
  - Scroll a large library against a real server on the smallest supported
    iPhone and on an iPad.
  - Record Instruments Allocations and the VM tracker. Pass: retained image
    memory after scrolling stops stays within the retained budget (≤ 70 MiB on
    iPhone), peak image memory while flinging stays within the peak budget
    (≤ 102 MiB on iPhone), and there are no hitches beyond one frame. If peak
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
