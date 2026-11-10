# 0007. Streaming strategy and minimum server version
- Status: Accepted
- Date: 2026-11-09
- Issue: #48 (P2-02)

## Context

The native app must stream audiobooks and podcast episodes with `AVPlayer` on iOS, iPadOS, iPhone Duo, macOS and CarPlay (minimum OS 27.0). The audio comes from an Audiobookshelf server. Most of those servers need authentication, and some sit behind reverse proxies.

The legacy Capacitor app authenticates its HLS transcode stream with the string literal `"AVURLAssetHTTPHeaderFieldsKey"` (`ios/App/Shared/player/AudioPlayer.swift:581-587`). That key is not public API. The iOS 27.2 SDK `AVAsset.h` declares no `HTTPHeaderFieldsKey` constant. AVFoundation's `.tbd` does list `_AVURLAssetHTTPHeaderFieldsKey`, but the leading `_` is Mach-O C symbol mangling: the binary exports a constant named `AVURLAssetHTTPHeaderFieldsKey` that is unpublished and undocumented (see [platform API research §3.4](../research/platform-apis.md)). We will not ship it.

Server facts below come from the server source at `advplyr/audiobookshelf` `master` @ `83dce682e88c2b32b0c33a8f83a9457bfc459e0e` (latest tag v2.37.2) and from tags `v2.22.0` (`25c7e95a`) and `v2.26.0` (`264ae928`).

**Starting a play session.**

- **Routes.** `POST /api/items/:id/play` and `POST /api/items/:id/play/:episodeId` (`server/routers/ApiRouter.js:118-119`). Both go to `PlaybackSessionManager.startSessionRequest`, which uses `req.body` as the options.
- **Body fields:**
  - `deviceInfo`: `deviceId`, `clientName`, `clientVersion`, `manufacturer`, `model`, `sdkVersion` (`server/objects/DeviceInfo.js:84-106`).
  - `supportedMimeTypes`
  - `forceDirectPlay`
  - `forceTranscode`
  - `mediaPlayer` (default `'unknown'`)
- **Play method.** `shouldDirectPlay = options.forceDirectPlay || (!options.forceTranscode && media.checkCanDirectPlay(options.supportedMimeTypes, episodeId))` (`server/managers/PlaybackSessionManager.js:321`). Both flags are tested for truthiness, so JSON booleans work.
- **Direct-play check.**
  - Books: `Book.checkCanDirectPlay` needs *every* included audio file's `mimeType` to be in `supportedMimeTypes` (`server/models/Book.js:278-284`).
  - Podcasts: `Podcast.checkCanDirectPlay` checks the episode's single file (`server/models/Podcast.js:302-313`).
  - If `supportedMimeTypes` is not an array, the check returns `false`, so the server transcodes.
- **Server MIME types** (`server/utils/constants.js:36-58`). They come from the file extension:
  - mp3 → `audio/mpeg`
  - m4b, m4a, mp4 → `audio/mp4`
  - ogg, oga, **opus** → `audio/ogg`
  - aac → `audio/aac`
  - flac → `audio/flac`
  - wma → `audio/x-ms-wma`
  - aiff, aif → `audio/x-aiff`
  - webm, webma → `audio/webm`
  - mka → `audio/x-matroska`
  - awb → `audio/amr-wb`
  - caf → `audio/x-caf`
  - Unknown formats fall back to `audio/mpeg` (`server/objects/files/AudioFile.js:103-109`).
  - Opus and Vorbis are **indistinguishable** (`audio/ogg`).
- **One open session per user and device.** Starting a session closes every open session for the same user and `deviceInfo.deviceId` (`PlaybackSessionManager.js:314-319`).
- **Legacy request.** The legacy iOS app always sends `forceDirectPlay: "1"` and never sends `supportedMimeTypes` (`ios/App/Shared/util/ApiClient.swift:460-499`). When `AVPlayer` fails, it retries with `forceTranscode` (`ios/App/App/plugins/AbsAudioPlayer.swift:270-290`). Android does the same (`PlayerNotificationService.kt:1105-1111`). The web client sends `supportedMimeTypes` from `canPlayType` (`client/players/PlayerHandler.js:183-192`).

**Direct play: `/public/session/:id/track/:index`.**

- **Added in v2.22.0.**
  - Commit `336de49d`, "Add new api endpoint for direct playing audio files using session id #4259", merged in PR #4263.
  - The v2.22.0 release notes (2025-05-14) call it the "now preferred method".
- **Route.** Mounted on `/public` **with no auth middleware** (`server/Server.js:347`, `server/routers/PublicRouter.js:22`). The unguessable session id is the only credential, and the URL works only while the session is open in server memory.
- **Response** (`server/controllers/SessionController.js:279-330`):
  - It uses `res.sendFile`, which honours `Range`.
  - It sets `Content-Type` from the extension because "Express does not set the correct mimetype for m4b files".
  - With `X-Accel`, it returns `204` plus `X-Accel-Redirect`, and nginx serves the file with whatever type nginx picks.
- **Later fixes:**
  - v2.26.3 (`8c38987d`): matches `toNumber(t.index, 1)` and accepts index `0` for podcast episodes whose track `index` is `null` (episodes created before v2.21.0). Before this fix, such tracks cannot be addressed and return 404.
  - v2.28.0 (`794f0ef4`): redirects transcode sessions to their HLS `contentUrl` instead of crashing.

**HLS transcode: `/hls/:stream/:file`.**

- **No user auth since v2.22.0.** Commit `1f7b181b` "Update HLS stream endpoints to not include user token" (PR #4266, release note: "HLS stream endpoint no longer requires user token in URL") changed `router.use('/hls', this.authMiddleware…)` to `router.use('/hls', this.hlsRouter.router)`. Current: `server/Server.js:346`.
- **Access control.** `HlsRouter` only checks that the stream id is an open stream, that the file stays inside the stream directory, and that the extension is `.ts` or `.m3u8` (`server/routers/HlsRouter.js:51-96`). So `?token=` on `/hls` is neither needed nor read.
- **Format.** The playlist is `/hls/{sessionId}/output.m3u8` (`server/objects/Stream.js:101`). It uses **relative** segment URIs `output-N.ts`: MPEG-TS, `-hls_time 6`, VOD (`server/utils/generators/hlsPlaylistGenerator.js`, `Stream.js:83-84,286`). Audio is copied or re-encoded to AAC (`Stream.js:270-282`).

**Authenticated file route: `/api/items/:id/file/:fileid`.**

- **Route.** `server/routers/ApiRouter.js:125`. It sits behind `/api` auth (`Server.js:345`).
- **Token sources.** The JWT strategy reads the token from `Authorization: Bearer` **or the `?token=` query parameter**: `ExtractJwt.fromExtractors([fromAuthHeaderAsBearerToken(), fromUrlQueryParameter('token')])` (`server/Auth.js:126`). It has done so since commit `0d5a30b2` (2023-09-25), so it applies to all `/api` routes.
- **Expiry.** Since v2.26.0 (PR #4444, JWT access and refresh tokens), access tokens expire. The default is `ACCESS_TOKEN_EXPIRY` = **1 hour** (`server/auth/TokenManager.js:19`). Expiry is enforced in `jwtAuthCheck` (`TokenManager.js:313-316`). A `?token=` URL baked into an `AVURLAsset` therefore stops working mid-book.

**Session sync and close.**

- **Open-session routes** (`ApiRouter.js:242-244`) go through `openSessionMiddleware`, which checks that the session exists in memory and belongs to the user or an admin:
  - `POST /api/session/:id/sync` with `{currentTime, timeListened, duration}` (`PlaybackSessionManager.js:386-396`)
  - `POST /api/session/:id/close` (optional sync body)
  - `GET /api/session/:id`
- **Offline sessions.** `POST /api/session/local` and `POST /api/session/local-all` (`ApiRouter.js:239-240`). The server rewrites ids that start with `play_local_` to a fresh UUID through an **in-memory** map (`PlaybackSessionManager.js:153-161`), so a resend after a server restart creates a duplicate.
- **When open sessions end.** They live only in memory and are lost on a server restart. The server closes them after 36 hours without an update (`closeStaleOpenSessions`, `PlaybackSessionManager.js:486-497`), and when the same device starts a new session (see above).

**Version discovery.**

`GET /status` (no auth) returns `serverVersion` (`server/Server.js:375-390`). Login responses carry `serverSettings.version`.

**Custom headers in the legacy app.**

- **Where headers are sent.** The connect form stores per-server `customHeaders` (`components/modals/CustomHeadersModal.vue`) but sends them only on `/ping` and `/login` (`components/connection/ServerConnectForm.vue:620-641`).
- **Where they are not sent.** No other JS, Swift or Kotlin code reads `customHeaders`: not `plugins/nativeHttp.js`, not the Alamofire `ApiClient.swift`, and not `AVPlayer` or ExoPlayer.
- **Effect.** A proxy that requires a header on *every* request already breaks streaming in the legacy app.

## Decision drivers

1. **No private API.** App Review risk, and its behaviour is undefined for HLS segment requests.
2. **Seeking must keep working on long books.** That means byte-range requests over hours of playback, beyond the 1-hour access-token lifetime.
3. **Keep user tokens out of URLs** where possible, because URLs end up in proxy and server access logs.
4. **Work with `AVPlayer`/`AVQueuePlayer` as designed:** system buffering, AirPlay, CarPlay, Now Playing, and background audio on iOS and macOS.
5. **Support users behind header-gated reverse proxies** at least as well as the legacy app does.
6. **Keep a small, testable surface** with one server-version floor rather than many runtime branches.
7. **Plan for offline (downloaded) playback** and its progress sync.

## Options considered

### Option 1: Direct play through the public session track URL, HLS fallback, plain `AVURLAsset`

- Start a session with `supportedMimeTypes`.
- If `playMethod == 0`, play `/public/session/{id}/track/{index}` for each audio track.
- If `playMethod == 2`, play the session's single `audioTracks[0].contentUrl` (`/hls/{id}/output.m3u8`).
- Neither URL needs credentials on servers ≥ 2.22.0.

Pros:
- No credentials in headers or URLs. Nothing expires during playback except the session itself.
- Uses plain `AVURLAsset`, so system range requests, buffering and AirPlay all work.
- The same code path covers HLS, because `/hls` has been unauthenticated since 2.22.0.
- It is the server's documented "preferred method" (v2.22.0 release notes).

Cons:
- The URL only works while the server-side session is open. It breaks on a server restart, a 36-hour idle period, or a new session from the same `deviceId`. The client must detect a lost session (confirmed with `GET /api/session/{id}`) and re-open it.
- The session id is a bearer capability. Anyone who sees the URL can fetch the track until the session closes.
- The URL has no file extension, so the app must pass the MIME type explicitly.
- Does not help header-gated proxies.

### Option 2: `?token=` query parameter on `/api/items/:id/file/:ino`

Pros:
- Works on every server version. It is the legacy path for servers below 2.22.0 and the legacy local-file fallback (`AudioPlayer.swift:568,576`).
- Independent of session lifetime.

Cons:
- On servers ≥ 2.26.0 the access token expires after 1 hour by default. An `AVURLAsset` URL cannot be refreshed in place, so mid-book range requests fail with 401. Re-creating the item on every refresh causes audible gaps.
- Puts the user's access token into access logs and proxy logs.
- Does not help header-gated proxies.
- Useless for `/hls`, which ignores the token.

### Option 3: Private `"AVURLAssetHTTPHeaderFieldsKey"` option (legacy HLS path)

Pros:
- One line. Currently works for progressive files.

Cons:
- Not public API, and absent from the iOS and macOS 27.2 SDK headers. This is a rejection risk.
- Its behaviour on HLS segment and key requests is undocumented and unverified.
- Could break silently in any OS release.

### Option 4: `AVAssetResourceLoaderDelegate` with a custom URL scheme

- Rewrite `https://…` to a custom scheme such as `abs-https://…`.
- The delegate re-issues each request with `URLSession`, adding headers, and feeds the bytes back to AVFoundation.
- A throwaway spike in `/tmp` was typechecked with Swift 6 and Xcode 27.2 for `arm64-apple-ios27.0` and `arm64-apple-macos27.0`, then deleted. It confirmed the API shape:
  - `shouldWaitForLoadingOfRequestedResource`
  - `contentInformationRequest`: `contentType` via `UTType(mimeType:)`, `contentLength` from `Content-Range`, `isByteRangeAccessSupported`
  - `dataRequest.requestedOffset` and `requestedLength` mapped to a `Range` header
  - `respond(with:)` and `finishLoading`
  - Under Swift 6 strict concurrency, an `@unchecked Sendable` class confined to a serial queue.

Pros:
- Public API. Allows arbitrary headers on every byte-range request of a progressive file, so it is the only public option that satisfies header-gated proxies.
- Headers are read from the live server config, so they can change without rebuilding the asset.

Cons:
- We own buffering, range splitting, cancellation and errors, and lose system HTTP caching.
- AirPlay to a receiver that fetches the URL itself cannot follow a custom scheme.
- Unsuitable for HLS. AVFoundation's resource loader is generally understood to serve playlists and keys, while media segments must be redirected to real http(s) URLs. That understanding comes from general knowledge and was not re-verified for OS 27. Segment requests would therefore go out without the headers.
- More code and more tests.

### Option 5: Local loopback HTTP proxy

Pros:
- Can inject headers for progressive files *and* HLS segments.

Cons:
- Needs an in-process HTTP server: a socket listener, the macOS sandbox `network.server` entitlement, and an ATS/localhost exception.
- Must stay alive in the background, and needs lifecycle handling around CarPlay and interruptions.
- Much larger attack and maintenance surface for a niche case.

## Decision

1. **Minimum server version: 2.26.0.** **Provisional: pending owner (@djensenius) sign-off, tracked in #48.** Implementation proceeds against 2.26.0, because lowering the floor later only adds code paths; it removes none. The rest of this ADR (the streaming and auth design) is Accepted. 2.26.0 includes:
   - the public session track route (≥ 2.22.0)
   - unauthenticated HLS (≥ 2.22.0)
   - JWT access and refresh tokens (≥ 2.26.0), which the auth design relies on

   **Compatibility break.** The legacy app has no minimum version; its `requiredServerVersion` check is commented out (`ServerConnectForm.vue:100,740-741`). It still supports servers below 2.26.0:
   - It keeps using the old non-expiring `user.token` (`ServerConnectForm.vue:870-872`).
   - It only shows a non-blocking "old server auth" warning (`ServerConnectForm.vue:24-27,176-178`).
   - It forces a re-login only on servers **≥ 2.26.0** that still hold an old token (`layouts/default.vue:180-195`).
   - It streams with `?token=` below 2.22.0 (`AudioPlayer.swift:565-569`).

   So this floor **drops servers the legacy app still supports**: everyone on 2.25.x or older (2.26.0 shipped 2025-07-12). Those users see a clear "server too old" message at sign-in (below) and must upgrade the server to 2.26.0 or newer before they can use the native app. The legacy app keeps working for them.

   **Gating:**
   - **Before sign-in:** read `GET /status` `serverVersion`. If it is below 2.26.0 or unparseable, block sign-in with a localised "This server runs Audiobookshelf X. Version 2.26.0 or newer is required." message and a link to the server upgrade docs.
   - **After every login or authorize:** re-check `serverSettings.version`. If the server has been downgraded, show a blocking banner and disable playback.
   - **Finer gates** live in `ServerFeatures` (ABSCore, P1-03 #26), derived from the version. There is only one today:
     - **Below 2.26.3:** a podcast episode track whose `index` is `null` cannot be addressed on the public route, because `getTrack` matched `t.index === index`. For that case only, use Option 2 (`/api/items/{id}/file/{ino}?token=`). Refresh the access token immediately before creating the item, and accept the 1-hour limit, because episodes are usually short.
     - **2.26.3 and newer:** use the public route with `track.index ?? 0`. See point 2.
2. **Direct play (the default) uses Option 1.**
   - Start the session with this JSON body:
     - `deviceInfo`:
       - `deviceId`: a stable device UUID stored in the Keychain, because `identifierForVendor` does not exist on macOS. Keychain items survive app deletion and reinstall, so the server keeps seeing the same device
       - `clientName`: "Audiobookshelf Apple"
       - `clientVersion`
       - `manufacturer`: "Apple"
       - `model`: hardware identifier
       - `sdkVersion`: OS version
     - `mediaPlayer: "AVPlayer"`
     - `supportedMimeTypes`
     - `forceDirectPlay: false`
     - `forceTranscode: false`
   - Unlike the legacy app, we do **not** force direct play. The server decides from `supportedMimeTypes`.
   - For each `audioTracks[i]`, build `AVURLAsset(url: <server>/public/session/{id}/track/{track.index ?? 0}, options: [AVURLAssetOverrideMIMETypeKey: track.mimeType, AVURLAssetHTTPUserAgentKey: …])`.
     - **Never interpolate a `nil` index.** `getTrack` parses the path with `toNumber(req.params.index, null)` and returns `400` for a non-numeric value such as `"null"` (`SessionController.js:280-284`; `server/utils/index.js:168-171`).
     - **Why a track index can be null.** `AudioTrack.toJSON()` serialises `index` as-is (`server/objects/files/AudioTrack.js:3,15`). Since 2.26.3, `PodcastEpisode.getAudioTrack` sets `index = 1` on new sessions (`server/models/PodcastEpisode.js:188`, commit `8c38987d`). The client still treats `index` as optional, for older stored episodes, open sessions and other payloads.
     - **Why `0` works** on ≥ 2.26.3: for podcasts, route index `0` falls back to `audioTracks[0]`. A stored `null` also matches route index `1` through `toNumber(t.index, 1)` (`SessionController.js:292-297`).
     - Below 2.26.3, `ServerFeatures` routes null-index tracks to the token fallback in point 1.
     - `AVURLAssetOverrideMIMETypeKey` is public on iOS 17 and macOS 14.
     - It is needed because the path has no extension and X-Accel deployments may send a generic type.
3. **HLS fallback.**
   - **Planned fallback:** if the session comes back with `playMethod == 2`, play `<server> + audioTracks[0].contentUrl` with a plain `AVURLAsset`. That single item covers the whole book.
   - **Recovery on any item failure, stall, or HTTP error.** `GET /api/session/{id}` is **authoritative**: `openSessionMiddleware` returns 404 only when the session is no longer open (`SessionController.js:338-349`).
     1. **Session gone (404).** Session loss. Re-open the session in the same mode and resume at the last known position.
     2. **Session exists, HLS segment 404.** The segment is not ready yet. That happens while ffmpeg is still producing it, or after an unbuffered seek makes the server reset the transcode: `HlsRouter` returns 404 for a missing `.ts` and may restart ffmpeg at the requested segment, emitting socket `stream_reset {startTime, streamId}` (`server/routers/HlsRouter.js:74-94`).
        - Retry segment readiness with exponential backoff: 0.5 s, 1 s, 2 s, 4 s, 8 s. That is at most 5 retries and about 15.5 s in total, then the attempt is abandoned. Retry by re-seeking the current item to the current time. The playlist URL and session stay unchanged.
        - If a `stream_reset` for this session arrives, seek to its `startTime` and restart the backoff once.
        - After the bounds are exhausted, re-check the session. If it still exists, close it and re-open it in the same mode at the last known position. Do this at most once, then surface an error.
     3. **Session exists, direct-play decode or format error.** Examples: `AVError.fileFormatNotRecognized`, `.decodeFailed`. Close the session and re-open it once with `forceTranscode: true`, resuming at the current position. This matches legacy behaviour.
     4. **Session exists, other network errors** on direct play: retry with the same bounded backoff, then surface an error. Never transcode because of a network error.
   - **Detecting the failure on a plain `AVURLAsset`.** AVFoundation does not hand the app the HTTP response:
     - Observe `AVPlayerItem.status == .failed` and `AVPlayerItemFailedToPlayToEndTime` (`AVPlayerItemFailedToPlayToEndTimeErrorKey`).
     - On a failure or a stall (`AVPlayerItemPlaybackStalled`), read the `AVPlayerItem.errorLog()` events (`AVPlayerItemNewErrorLogEntry`). For HTTP failures, `errorStatusCode` and `errorComment` usually carry the HTTP status, for example `404` with "HTTP 404: File Not Found" in `CoreMediaErrorDomain`. This is typical for HLS. Whether progressive items fill the error log is unverified.
     - The HTTP status is only a hint for choosing the branch above. The session lookup always decides between session loss and the other cases.
     - The resource-loader path sees the `HTTPURLResponse` directly and maps 404 the same way.
4. **`supportedMimeTypes` are computed at runtime, not hard-coded.**
   - Take the server's audio MIME set: `audio/mpeg`, `audio/mp4`, `audio/aac`, `audio/flac`, `audio/x-caf`, `audio/x-aiff`, `audio/ogg`, `audio/webm`, `audio/x-matroska`, `audio/x-ms-wma`, `audio/amr-wb`.
   - Keep each type for which `AVURLAsset.isPlayableExtendedMIMEType(_:)` returns true.
   - Then apply a **denylist** owned by this ADR. It starts with `audio/ogg` and `audio/amr-wb`:
     - `audio/ogg` covers both Vorbis and Opus, and progressive Ogg seeking over HTTP in `AVPlayer` is unproven.
     - AMR-WB is not in `AVURLAsset.audiovisualMIMETypes()`.
   - Remove a denylist entry only when the validation matrix in #49 shows it passes on both iOS and macOS.
   - Expected result on OS 27: `audio/mpeg`, `audio/mp4`, `audio/aac`, `audio/flac`, `audio/x-caf`, `audio/x-aiff`. A runtime probe on macOS 27.2 returned `true` for all six, and `false` for webm, matroska and wma.
   - A multi-file book with any denied file is transcoded as a whole, because `Book.checkCanDirectPlay` uses `every`.
5. **Multi-track books** use one `AVPlayerItem` per track in an `AVQueuePlayer` (`actionAtItemEnd = .advance`).
   - Map global time to track and offset using the session's per-track `startOffset` and `duration`.
   - A seek into another track rebuilds the queue from the target track.
   - We rejected `AVMutableComposition`, which must load every remote asset's tracks up front and is slow for books with 100+ mp3 files.
   - HLS sessions always have exactly one track.
   - Engine details belong to the playback-engine issue.
6. **Custom-header servers.**
   - When a server config has custom headers, the app sends them on **all** `URLSession` API and download requests. That is broader than the legacy app, which sends them only on ping and login. Header values are secrets and live in the Keychain.
   - **Direct play** uses Option 4: a custom-scheme resource loader, used only for that server. It adds the custom headers and nothing else, because `/public/session` needs no Bearer token.
   - If the only custom header is `Cookie`, pass it with the public `AVURLAssetHTTPCookiesKey` on a plain asset instead. We assume that key also covers HLS segment requests; validation must confirm it.
   - **HLS with non-cookie custom headers is not supported** (Option 4 cannot cover segments, and Options 3 and 5 are rejected).
     - If such a server returns `playMethod == 2`, show "This file needs server transcoding, which isn't available when custom headers are configured."
     - Add a hint to let `/public/session/*` and `/hls/*` through the proxy without the header. On the Audiobookshelf side those paths are already protected only by unguessable session ids.
7. **Local (downloaded) playback.**
   - Play files with `AVURLAsset(url: fileURL)`, with no network involved.
   - Create a local `PlaybackSession` with:
     - `playMethod = 3`
     - an `id` that is a **UUIDv4**, not `play_local_…`, so resends stay idempotent across server restarts
     - `deviceInfo`
     - `mediaPlayer: "AVPlayer"`
     - the server's `libraryItemId` and `episodeId`
   - **Online:** report with `POST /api/session/local` while playing.
   - **After reconnecting:** batch unsent sessions with `POST /api/session/local-all`.
   - Before a session starts, server progress that is newer than local progress wins, as in the legacy flow (`ApiClient.swift:532-591`).
   - A downloaded item never falls back to streaming silently. A missing file is shown as an error with a "Stream instead" action, which starts a normal server session.
   - **Downloads themselves** (fetching files for offline use) do **not** use `?token=`. That differs from the legacy app (`AbsDownloader.swift:454`):
     - Request `/api/items/{id}/file/{ino}/download` with an `Authorization: Bearer` header plus any custom headers.
     - Refresh the access token before **creating** each background `URLSession` task, because a task can sit queued longer than the 1-hour token lifetime.
     - **Resume data keeps the old request.** `downloadTask(withResumeData:)` restores the original request, including its old `Authorization` header, and cannot take a replacement `URLRequest`. Resume data is therefore only usable while the credentials it was created with are still valid.
     - **On HTTP 401 or a credential change** (token refresh, re-login, edited custom headers), discard any stale resume data. Recreate the task from a fresh `URLRequest` that carries the current headers.
     - This is a **full restart** of that file. A `Range`-based partial restart is not adopted, because range support on the `/download` route was not verified. Revisit it if #49 or the downloads work proves `206` responses there.
     - An already-running task is not cancelled when the token refreshes. The server authenticates a request once, when it starts.
     - Store only token-free server paths and local file paths in SwiftData. Never store signed or tokenised URLs.
8. **Streaming sessions:**
   - Sync with `POST /api/session/{id}/sync` `{currentTime, timeListened, duration}`.
   - Close with `POST /api/session/{id}/close` when playback stops, the item changes or the user signs out.
   - These calls use `Authorization: Bearer` (plus any custom headers) through the shared API client with token refresh.

## Consequences

- **No private API.** Playback adds no App Review exposure beyond the CarPlay and audio entitlements.
- **Old servers are refused. This is a deliberate compatibility break with the legacy app.**
  - **Who:** users on servers below 2.26.0. The legacy app still supports them with the old non-expiring token and only a soft warning.
  - **What they see:** a blocking "This server runs Audiobookshelf X. Version 2.26.0 or newer is required." message at sign-in, with upgrade guidance.
  - **What they must do:** upgrade the server (2.26.0 shipped 2025-07-12; the current release is v2.37.2).
  - **Not yet settled:** the floor is provisional until the owner signs off (#48).
- **New failure mode.** Expired access tokens can no longer cause mid-playback 401s, because streaming URLs carry no user token. Losing the session (restart, 36-hour idle, same-device takeover) is now the main failure mode, and the engine must handle it.
- **Session ids are capabilities.** Never log full track URLs at info level.
- **Header-gated proxies.** Users get direct play through a resource loader that we must maintain and test, but no transcode. This is a documented limitation, and still better than the legacy app, whose streaming ignored custom headers entirely.
- **Ogg books transcode.** Vorbis and Opus books will transcode until the matrix proves direct play works. This costs server CPU but plays reliably.
- **One `?token=` path remains,** for null-index podcast episodes on servers 2.26.0–2.26.2. Delete it when the floor is raised to 2.26.3 or later.

## Validation

**Acceptance.**
- **Accepted:** the streaming and auth design (decisions 2–8).
- **Provisional:** the minimum server version (decision 1, 2.26.0), pending the owner's (@djensenius) sign-off, tracked in #48. Issue #48 requires that sign-off, and coordinator approval does not replace it.
- **Meanwhile:** implementation targets 2.26.0. If the owner chooses a lower floor, a follow-up ADR adds the older code paths (`?token=` streaming, the old non-expiring token); nothing built against 2.26.0 has to be removed.

**Device validation is performed in #49 (P2-03).** It is part of that issue's acceptance criteria. The matrix below is the expected behaviour, derived from the server source. #49 records the observed results on a physical iPhone (iOS 27) and a Mac (macOS 27) against real servers. For each cell, #49 checks:
  - start
  - seek ±1 h
  - seek into an unbuffered range
  - the track boundary (multi-file mp3)
  - resume after more than 1 h paused

| Server | m4b (single file) | Multi-file mp3 | Opus (`.opus` → `audio/ogg`) | FLAC |
|---|---|---|---|---|
| < 2.22.0 | Blocked at sign-in | Blocked | Blocked | Blocked |
| 2.22.0–2.25.x | Blocked (pre-JWT auth) | Blocked | Blocked | Blocked |
| 2.26.0–2.26.2 | Direct play, public track | Direct play, N items in `AVQueuePlayer` | HLS transcode (denylisted) | Direct play |
| 2.26.3–2.27.x | as above | as above | as above | as above |
| ≥ 2.28.0 (test on 2.37.2) | as above | as above | as above | as above |
| Any ≥ 2.26.0 behind a custom-header proxy | Direct play via resource loader | Direct play via resource loader | Error (needs transcode) | Direct play via resource loader |

**Additional checks in #49,** on one supported server:
- `forceTranscode: true` on an m4b returns `playMethod 2`, and `/hls/…/output.m3u8` plays without any `Authorization` header.
- `forceDirectPlay: true` on a `.wma` returns `playMethod 0`, and `AVPlayer` fails. This confirms the app must never send `forceDirectPlay: true` blindly.
- `curl -r 1000-1999` on the public track URL returns `206` with `Content-Range`, both with and without X-Accel (nginx).
- After a server restart, the track URL returns 404, and the app re-opens the session.
- Uploading the same local session (same UUID) twice does not create a duplicate.
- `AVURLAssetHTTPCookiesKey` cookies reach HLS segment requests.

**Verified from source and SDK:**
- Every server behaviour cited in Context, with file paths at the commits listed.
- SDK header facts: no published header-fields key; `AVURLAssetOverrideMIMETypeKey` is available from iOS 17; `AVURLAssetHTTPCookiesKey` and `AVURLAssetHTTPUserAgentKey` are public.
- The resource-loader API shape typechecks under Swift 6 for iOS and macOS 27.
- The MIME probe ran on macOS 27.2 only.

**Assumed, not verified:**
- `AVPlayer` seek and range behaviour against the public route.
- iOS results from `isPlayableExtendedMIMEType`.
- Resource-loader limits for HLS segments.
- Cookie propagation to HLS segments.
- HTTP status reporting through `AVPlayerItem.errorLog()` for progressive (non-HLS) items.
- Express `sendFile` range support (the documented default of the `send` module, not re-read).

## References

- Issue spec P2-02. Legacy references:
  - `ios/App/Shared/player/AudioPlayer.swift:556-590`
  - `ios/App/Shared/util/ApiClient.swift:460-499`
  - `ios/App/App/plugins/AbsAudioPlayer.swift:270-290`
  - `plugins/capacitor/AbsAudioPlayer.js`
  - `components/connection/ServerConnectForm.vue`
- [Platform API research §3.3–3.4](../research/platform-apis.md)
- [Legacy API inventory](../research/legacy-api-inventory.md)
- Audiobookshelf server, `advplyr/audiobookshelf` @ `83dce682`:
  - `server/Server.js`: routes at 345-347, `/status` at 375-390
  - `server/routers/PublicRouter.js`
  - `server/routers/HlsRouter.js`
  - `server/routers/ApiRouter.js`: 118-125, 239-244
  - `server/controllers/SessionController.js`: `getTrack` at 279-330, `openSessionMiddleware` at 338-349
  - `server/managers/PlaybackSessionManager.js`: 52-86, 150-215, 313-364, 373-396, 486-497
  - `server/models/Book.js:278-303`
  - `server/models/Podcast.js:302-333`
  - `server/utils/constants.js:29-58`
  - `server/objects/files/AudioFile.js:103-109`
  - `server/objects/Stream.js`
  - `server/utils/generators/hlsPlaylistGenerator.js`
  - `server/Auth.js:126`
  - `server/auth/TokenManager.js`: 17-27, 277-336
  - `server/objects/DeviceInfo.js:84-106`
- Server commits:
  - `336de49d` and `1f7b181b`: v2.22.0, PRs #4263 and #4266
  - `8c38987d`: v2.26.3
  - `794f0ef4`: v2.28.0
  - `0d5a30b2`: query-token extractor
- Server releases v2.22.0 (2025-05-14) and v2.26.0 (2025-07-12). Auth migration: advplyr/audiobookshelf discussion #4460.
- Apple iOS 27.2 SDK, `AVFoundation.framework/Headers/AVAsset.h`:
  - `AVURLAssetOverrideMIMETypeKey`, l.558
  - `AVURLAssetHTTPCookiesKey`, l.577
  - `AVURLAssetHTTPUserAgentKey`, l.614
  - See also `AVAssetResourceLoader.h`.
