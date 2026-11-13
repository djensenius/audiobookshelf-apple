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
- The delegate re-issues each request with `URLSession`, adding the server's custom proxy headers (never `Authorization` or `Cookie`; see Decision 6), and feeds the bytes back to AVFoundation.
- A throwaway spike in `/tmp` was typechecked with Swift 6 and Xcode 27.2 for `arm64-apple-ios27.0` and `arm64-apple-macos27.0`, then deleted. It confirmed the API shape:
  - `shouldWaitForLoadingOfRequestedResource`
  - `contentInformationRequest`: `contentType` via `UTType(mimeType:)`, `contentLength` from `Content-Range`, `isByteRangeAccessSupported`
  - `dataRequest.requestedOffset` and `requestedLength` mapped to a `Range` header
  - `respond(with:)` and `finishLoading`
  - Under Swift 6 strict concurrency, an `@unchecked Sendable` class confined to a serial queue.

Pros:
- Public API. Allows custom headers on every byte-range request of a progressive file, so it is the only public option that satisfies header-gated proxies.
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
   - **Detecting failures on a plain `AVURLAsset`.** AVFoundation does not hand the app the HTTP response, so the engine watches:
     - `AVPlayerItem.status == .failed` (`item.error`);
     - `AVPlayer.status == .failed`;
     - `AVPlayerItemFailedToPlayToEndTime` (`AVPlayerItemFailedToPlayToEndTimeErrorKey`);
     - `AVPlayerItemPlaybackStalled`;
     - the `AVPlayerItem.errorLog()` events delivered by `AVPlayerItemNewErrorLogEntry`.
     For HTTP failures, `errorStatusCode` and `errorComment` usually carry the HTTP status, for example `404` with "HTTP 404: File Not Found" in `CoreMediaErrorDomain`. This is typical for HLS. Whether progressive items fill the error log is unverified. Network failures surface as an `NSURLErrorDomain` underlying error.
     The HTTP status is only a hint. `GET /api/session/{id}` decides between "session alive" and "session gone". `openSessionMiddleware` returns 404 only when the session is no longer open (`SessionController.js:338-349`). The resource-loader path sees the `HTTPURLResponse` directly and classifies it the same way.
   - **Failure classification.** Every failure falls into exactly one class.
     - **Recoverable, session alive:**
       - an HLS segment or playlist 404 while `GET /api/session/{id}` returns 200 (segment not ready yet, or a transcode reset);
       - HTTP 5xx, 408 or 429;
       - a stall with no error.
       → **segment-readiness retries** (below).
     - **Recoverable, session gone:**
       - `GET /api/session/{id}` returns 404. This happens when the transcode session was closed, after a 36-hour idle period, after a same-device takeover, or when the server restarted (sessions are in-memory, so `/hls/{id}/…` and `/public/session/{id}/…` then return 404 as well).
       → **session rebuild**.
     - **Network loss:**
       - `NSURLErrorNotConnectedToInternet`, `.networkConnectionLost`, `.timedOut`, `.cannotConnectToHost`, `.cannotFindHost` or `.dnsLookupFailed` (as `item.error`, as an underlying error, or in the error log);
       - the session lookup itself failing with one of these.
       → **network wait**, then a session check.
     - **Auth (HTTP 401)** on the playlist, a segment, a track or the session lookup → **401 path**.
     - **Decode or format:**
       - On direct play (`AVError.fileFormatNotRecognized`, `.decodeFailed`, similar codes) → the **direct-play to HLS fallback**: one session rebuild with `forceTranscode: true`. This matches legacy behaviour.
       - On an HLS session, the same error is **not** recoverable.
     - **Not recoverable, error shown immediately:**
       - HTTP 403;
       - TLS or certificate errors (`NSURLErrorServerCertificate*`, `.secureConnectionFailed`);
       - a decode error on HLS;
       - a second 401 within one recovery;
       - user cancellation.
   - **Segment-readiness retries (session alive).** The playlist URL and server session stay unchanged on every retry.
     - **Why a segment can be missing.** While ffmpeg is still producing a segment, or after an unbuffered seek makes the server reset the transcode, `HlsRouter` returns 404 for the missing `.ts`. It may restart ffmpeg at the requested segment and emit the socket event `stream_reset {startTime, streamId}` (`server/routers/HlsRouter.js:74-94`).
     - **Budget:** exponential backoff of 0.5 s, 1 s, 2 s, 4 s, 8 s. That is at most 5 retries and about 15.5 s in total.
     - **Each retry depends on the item's state:**
       - **Item not failed** (stalled, `AVPlayerItem.status != .failed`): re-seek the current item to the saved position.
       - **Item failed** (`AVPlayerItem.status == .failed`, which a seek cannot recover): create a new `AVURLAsset` and `AVPlayerItem` for the same playlist URL, replace the current item, and seek to the saved position.
       - **Player failed** (`AVPlayer.status == .failed`): also create a new player before inserting the item. Re-attach observers and the rate.
       - Re-seeks and item or player recreations all draw on the same budget.
     - **On `stream_reset`:** if one arrives for this session, apply it with the same item-state rule, seeking to the recovery target (see "Playback position across rebuilds"; the server's `startTime` is only used to know the reset happened), and restart the backoff once.
     - **When the budget is exhausted:** re-check the session. If it is gone, run a session rebuild. If it is still alive, escalate to a session rebuild too; the old session is closed in step 1 of the rebuild.
     - Direct play uses the same budget and item-state rule for 5xx, 408, 429 and stalls.
   - **Session rebuild** (session gone, readiness budget exhausted, or the direct-play to HLS fallback). The old `sessionId` is never reused.
     1. **Final sync and close of the old session.** Send the old session's unsynced listening time and the saved position (see "Playback position across rebuilds").
     2. **Open a new session.** Call `POST /api/items/:id/play[/:episodeId]` with the same body as the original. Keep `forceTranscode: true` if the old session was a forced transcode, and set it for the direct-play to HLS fallback.
     3. **Build the new item, or `AVQueuePlayer` items, from the new session's URLs.**
     4. **Restore the position and rate.**
     - **Budget:** at most **3** rebuild attempts per failure episode, with **1 s / 2 s / 4 s** backoff before attempts 1–3.
     - **What counts as an attempt:** an attempt fails if the `/play` call fails, or if the new item fails before its first confirmed time-observer tick.
     - **Episode reset:** the episode, and with it both budgets, resets after 30 s of confirmed playback.
     - **Giving up:** after the third failed attempt, stop. Keep the saved position, pause, and show "Can't continue streaming. Check your connection or server." with a Retry action. Retry starts a fresh episode.
   - **Network wait (network loss).**
     - **No budget spent offline:** do not retry while `NWPathMonitor` reports the path as unsatisfied. Pause in a "Waiting for network" state.
     - **Connectivity returns:** retry **immediately**, without backoff. First check the session. If it is alive, use the readiness rule; if it is gone, start a rebuild. That immediate retry counts as rebuild attempt 1 if a rebuild is needed.
     - **Satisfied path, still failing:** if the path is satisfied but requests still fail with network errors, treat each failure as a rebuild attempt, using the 3-attempt budget above.
     - **Giving up:** if the path stays unsatisfied for 5 minutes, stop with the same error and Retry action.
   - **401 path. Never loops.**
     - **Where a 401 can come from.** On supported servers (≥ 2.26.0) `/hls` and `/public/session` carry no user token, so Audiobookshelf itself never returns 401 there (`server/Server.js:346-347`). A 401 on media therefore comes from a fronting proxy, or arrives on the authenticated `GET /api/session/{id}`, `/play` or `/sync` calls.
     - **First 401 in a failure episode:** run the API client's single-flight refresh (`POST /auth/refresh`). If it succeeds, do one session rebuild; that rebuild counts against the 3-attempt budget.
     - **Second 401, or a failed refresh:** stop. A failed refresh leads to sign-in. A 401 on media after a successful refresh shows "The server or a proxy in front of it rejected the stream." Never refresh twice in one episode.
   - **Playback position across rebuilds.** This applies to every rebuild of the item or session: recovery, a quality change, the direct-play to HLS fallback, and an audio route change that recreates the player.
     - **Source of truth.** The position is the last value confirmed by the player's periodic time observer (`addPeriodicTimeObserver`, every 0.5 s). It is stored as global book time (track `startOffset` plus item time) and kept locally in the engine, persisted on pause and backgrounding.
       - It is updated only while the item is `.readyToPlay` and time advances.
       - Seeks set it when they complete.
       - It is **never** taken from the new session's `currentTime`. The server derives that from `mediaProgress`, which can be older than local playback.
       - The cold-start "newer progress wins" rule in point 7 applies only when a session starts fresh, not to a rebuild.
     - **Recovery target is the latest user intent.** Every seek gets an increasing `seekGeneration`, and the engine stores its target as `pendingSeekTarget` until the seek completes.
       - **Target:** a rebuild, re-seek or `stream_reset` targets `pendingSeekTarget` if a user seek is pending or in flight, and the saved position otherwise.
       - **Cancelled seeks:** a user seek cancelled by recovery (its completion returns `finished == false`, or the item is replaced) is not lost. `pendingSeekTarget` stays set until a seek to it completes.
       - **Seek during recovery:** a user seek issued during recovery replaces the recovery target. The recovery seeks there instead, and any recovery seek completion with an older generation is ignored and never writes the saved position.
       - The saved position and Now Playing elapsed time follow the latest target, never an older one.
     - **Final sync before close.** Before step 2 of a rebuild, the old session gets one `POST /api/session/{old}/close` with `{currentTime: savedPosition, timeListened: unsyncedDelta, duration}`.
       - The server applies that body through `syncSession` before removing the session (`PlaybackSessionManager.js:421-426`).
       - Doing this first also moves the user's progress forward. A new HLS `Stream` starts transcoding at the user's progress (`PlaybackSessionManager.js:345`, `Stream.js:241-263`), so this avoids a needless transcode reset.
       - If the device is offline or the `/close` gets no response, the close goes into the persisted close queue (`PendingSessionClose` in `LocalProgressStore`, #382), tagged with the old session id: its report and the edit time its position committed with. It is stored while the attempt is still out, so a relaunch finds it. If no stored copy exists when the attempt fails and the save after it fails too, the syncer holds the close in memory (at most 16, dropped and logged on detach), and the next drain saves it before anything else. The drain resends it once `reconcileDelay` has passed since an attempt that may have reached the server (backed off like `/sync`), and only if the admission rule admits it (point 8, "Stale writes"). Like the first attempt, each resend saves its attempt time before it goes out, and is not sent if that save fails. An acknowledged close is removed, and so is one the account's end suppressed or the server rejected for good (400, 410, 422), with its listening time logged as dropped. A 404 removes it too, settled as in "Reconciling an unacknowledged `/close`" below (#382): the first attempt's 404 means nothing applied, so its listening time is carried, and a resend's 404 is decided from the session's stored record (`CloseRetryTests`, `CloseReconciliationTests`, `ProgressLateCloseTests.aCloseIsResentOnlyWhileItCanStillCount`).
     - **Restoring the position.** The new item seeks to the saved position **before** playing.
       - Use `seek(to:toleranceBefore:toleranceAfter:)` with a small tolerance: 0 for direct play, ≤ 0.5 s for HLS.
       - Set `AVPlayer.defaultRate` to the saved rate before `play()`.
       - Play only after the seek completes, and only if playback was playing before the failure.
       - Re-apply the rate after `play()`, because AVPlayer can reset it.
       - The new session's first `/sync` reports the saved position.
     - **`timeListening` without double-counting.** The server adds each `timeListened` as a delta (`PlaybackSession.addListeningTime`, `server/objects/PlaybackSession.js:238`).
       - **Count wall-clock time, not media time.** Listening time is elapsed wall-clock time while playing, independent of rate: 60 s at 0.5× counts as 60 s, and so does 60 s at 2×. This matches the legacy app, which adds `now − updatedAt` only when `isPlaying` (legacy `ios/App/Shared/player/PlayerProgress.swift:46-56`, called from `AudioPlayer.swift:218`).
       - **Observer as a gate only.** The time observer only confirms that playback is happening. A tick credits the monotonic-clock time since the previous tick (`ContinuousClock`) only if `timeControlStatus == .playing`, the rate is above 0, and item time advanced since the previous tick.
       - **Guards.** A tick gap longer than 2× the observer interval (suspension, stall, rebuild) credits at most one interval. Ticks while seeking, waiting, rebuilding or paused credit 0. Seeks and skips never add time, because media-time jumps are not counted.
       - **One owner per delta.** Each delta belongs to exactly one session id. The engine also records `ackedTotal`, the sum of `timeListened` the server acknowledged for that session. The accumulator for the new session starts at 0.
       - **Reconciling an unacknowledged `/close`.** A 404 on a retried `/close` is ambiguous: the first attempt may have applied the delta before its 200 was lost, or the session may have vanished first (restart or expiry). The server persists every sync and close to the DB, but only when `timeListening > 0` (`saveSession`, `PlaybackSessionManager.js:433-441`). It then removes the session only from memory (`closeSession` / `removeSession`, `PlaybackSessionManager.js:421-455`). The stored record can therefore be read through `GET /api/me/item/listening-sessions/:libraryItemId/:episodeId?`, which returns the newest sessions first with `id`, `timeListening` and `currentTime` (`MeController.js:185`, `ApiRouter.js:531-534`; this route exists in v2.26.0). On a 404 after an unacknowledged `/close` that carried a delta:
         - **Record found and `timeListening ≥ ackedTotal + delta − 1 s`:** the delta was applied, so drop it.
         - **Record found with `timeListening ≈ ackedTotal`, or no record because nothing was ever saved:** the delta was not applied, so carry it into the new session's next `/sync`.
         - **Undecidable** (record not on the first page, values match neither case, or the lookup fails after the normal queue retries): drop the delta. This undercounts by at most one sync interval but never double-counts.
         - **As implemented (#382, `CloseReconciliation.swift`).** The close stores the `ackedTotal` read when it was captured, and `inFlightTotal`, the `timeListened` of a `/sync` still out then, which may apply after the close (0 when an earlier report's outcome is unknown too, unreconciled or dropped after its lookup failed until a later lookup reads the total, as that report's time could stand in for it). "Applied" needs the record to reach `ackedTotal + inFlightTotal + delta`; "not applied" accepts a record at `ackedTotal` or at `ackedTotal + inFlightTotal`, unless it also matches `ackedTotal + delta`. All comparisons use `reconcileTolerance` (0.5 s), as the `/sync` reconciliation below does, and "applied" is checked first, so time the client never learned of (a report whose answer was lost) can only make "not applied" undecidable. A missing record counts as "nothing was ever saved" only when nothing was acknowledged and the page lists every stored session of the media. The first attempt's 404 needs no lookup: the server answers 404 before applying anything (`openSessionMiddleware`, `SessionController.js:322-333`). A lookup that fails keeps the close and is retried by later drains, backed off like a resend and never resending; offline or cancelled attempts don't count, a lookup that fails after the syncer stopped saves nothing (a replacement scope may have settled the close since), and the sixth failure, a missing item (404) or a refusal for good is undecidable. Carried time is held in memory per media (`CloseRetryQueue.carried`, at most 16 media) and joins the media's next loaded session's report once, as recovered time; it is dropped on detach and lost on relaunch, which undercounts.
         - **A close that outlives its session.** The server's nightly sweep ends every open session with no update for 36 h, without saving it (`closeStaleOpenSessions`, `PlaybackSessionManager.js:484-492`), so a queued close's session is gone 72 h after capture (60 h plus a margin for clock drift, `closeSessionLifetime`). The drain then settles the close by the stored record without resending it, so an admission rule that keeps skipping it (a progress lookup that never merges) can't hold it forever.
         - **Listening time a session can no longer send (#383).** The pinned server adds a report's `timeListened`, as a delta, to whichever open session the report names, and stores it on that session's record (`syncSession` → `addListeningTime`, `PlaybackSessionManager.js:373-412`, `PlaybackSession.js:237-248` at v2.26.0). So time the server certainly never applied is carried, as a 404'd close's is (`CloseRetryQueue.carried`), and the media's next loaded session reports it once. Time that may have applied is dropped and logged. Case by case:
           - **A `/sync` answered 404**, abandoning its session or answered after the session closed: the server answers 404 in `openSessionMiddleware`, before the handler runs (`SessionController.js:322-324`, used by `/sync` and `/close` at `ApiRouter.js:237-238`), so nothing applied, and the report's time is carried. Time played after the abandon rides the session's `/close`, which meets the same 404 and is carried too. An abandoned session never takes carried time itself: it reports nothing more. A snapshot still unreconciled when the session is abandoned is dropped: its outcome is unknown, and the open-session lookup that would tell now answers 404.
           - **A `/sync` that never reached the server, or was turned away (408, 429), after its session closed**: the close wait gave up on it, so the close carried only later time, and its time is carried. One whose failure is ambiguous (a timeout, a lost response, 5xx) is dropped: it may have applied, and a closed session has no later report to reconcile it.
           - **A queued `/close` that admission skips** for a newer session or position, which is never resent: settled by the session's stored record, as a resend answered 404 is. The drain admits a close only once the retry delay (at least `reconcileDelay`) has passed since an attempt that may have reached the server, so that attempt has applied or never will, and the record decides as it does for a 404, whether or not the session is still open.
           - Carried time is held only in memory: dropped and logged when the syncer detaches or its transport is quiesced, and lost on a relaunch, which undercounts but never counts twice. The server dates listening by the session that reports it (`addListeningTime` dates a session on its first listening), so carried time counts toward the later session's day.
       - **Serialized, idempotent reporting.** Each session has one serial reporting queue, so at most one `/sync` or `/close` is in flight per session.
         - **Snapshot:** before a send, the engine moves the accumulated time into an immutable snapshot `{sessionId, seq, timeListened, currentTime}` and resets the accumulator. Time played afterwards accrues into the next snapshot.
         - **Retries:** a resend always carries the **same** snapshot. It never re-reads the accumulator or merges new time into an unacknowledged snapshot.
         - **No blind resend.** The pinned server applies every `/sync` body, with no `seq` check (`syncSession` → `addListeningTime`, `PlaybackSession.js:237-246` at v2.26.0). So a snapshot whose outcome is ambiguous (timeout, connection lost after send, relaunch with an unacknowledged send) is reconciled before any resend. A clear failure where the request never reached the server, such as a DNS or connect error, may be resent.
         - **Reconciling an ambiguous `/sync`.** `GET /api/session/:id` returns the open session's live in-memory `timeListening` (`ApiRouter.js:236`, `SessionController.getOpenSession` → `toJSONForClient`, v2.26.0). Because the queue is serial, no other report can change it in between.
           - **`timeListening ≥ ackedTotal + delta − 1 s`:** the snapshot was applied. Release it and add it to `ackedTotal`.
           - **`timeListening ≈ ackedTotal`:** the snapshot was not applied. Resend it once, and treat that resend's outcome the same way.
           - **404:** the session is gone. Use the stored-record reconciliation for `/close` above.
           - **Anything else, or the lookup fails:** drop the snapshot and log it. Delivery is at most once, matching the undecidable `/close` case, because wall-clock listening time is advisory.
         - **One owner per interval:** a snapshot is released only by a 200, or by the reconciliation outcome below. Only then is the next snapshot sent. Every interval of listening time belongs to exactly one snapshot.
         - **Coalescing:** a second close request (rebuild plus app exit, for example) waits for the pending close and adds no delta.
       - **Final report through `/close`.** It uses `/close` with a body, not `/sync`, so a blind retry can never re-apply it: the retry gets 404 and goes through reconciliation.
     - **Now Playing and CarPlay.** During a rebuild, the Now Playing session (`ABSPlayback/NowPlaying/`, which also feeds CarPlay) keeps publishing the saved position as elapsed time, with a buffering or paused state.
       - The new item's time is not published until its seek has completed.
       - Elapsed time never jumps back to the server's `currentTime`, or to 0.
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
   - **Reserved names.** User custom headers may **not** be named `Authorization` or `Cookie` (case-insensitive).
     - The API client rejects them when the server is configured, with `CustomHeaderError.reserved` (PR #128). The connect UI shows the reason.
     - The guidance tells the user to give the proxy a distinct header or a service token, for example Cloudflare Access `CF-Access-Client-Id` / `CF-Access-Client-Secret`.
     - `Authorization` always carries the Audiobookshelf `Bearer` token, so it can never conflict with a proxy's `Basic` or other scheme.
     - Custom headers never add or replace cookies, so `AVURLAssetHTTPCookiesKey` is not used.
   - When a server config has custom headers, the app sends them on **all** `URLSession` API and download requests, next to the app's own `Authorization: Bearer`. That is broader than the legacy app, which sends them only on ping and login. Header values are secrets and live in the Keychain.
   - **Direct play** uses Option 4: a custom-scheme resource loader, used only for that server. It adds the custom headers and nothing else. `/public/session` needs no Bearer token, and the loader never sends `Authorization` or `Cookie`.
     - **Deviation from Option 4 (#148):** the loader takes a snapshot of the custom headers when the stream is resolved, rather than reading the live server config. A header edited mid-session applies from the next resolved stream (the next play, or a session rebuild). This keeps the loader free of shared mutable state; a header-provider closure can replace the snapshot if live edits turn out to matter.
   - **HLS with custom headers is not supported** (Option 4 cannot cover segments, and Options 3 and 5 are rejected). A plain `AVURLAsset` has no public option for adding custom headers.
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
   - **After reconnecting:** batch unsent sessions with `POST /api/session/local-all`. Each account's `PlaybackScope` does it in `syncWithServer(isFirstSync:)` (`LocalSessionUploader`), after draining pending progress, at an online session start and after each reconnect: the session's, and the network path coming back online, even with the same account and client (#184).
   - Before a session starts, server progress that is newer than local progress wins, as in the legacy flow (`ApiClient.swift:532-591`).
     - Newer means saved later. An unsent edit is dated by its edit time, a synced group by the later of its edit time and the server's `lastUpdate`. That date covers the whole row, so for a synced group it is only an upper bound on when the group last changed. Equal dates go to the server, as in the sync merge (ADR 0003).
     - An unsent audio edit is kept when the server's audio still equals what the row last saw, however new its `lastUpdate`: another device changed something else, such as the ebook position or the finished flag.
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
   - **Active baseline refresh (#281).** After a progress drain's dirty-row and PATCH-acknowledgement confirmation work, the still-loaded session's key gets one canonical `GET /api/me/progress/:id` if that drain has not already issued a GET for it. There is no timer or immediate retry; a reconnect refreshes through the playback scope's drain (#184). The refresh never sends a sync, PATCH or close.
     - GET-attempt deduplication is separate from acknowledgement accounting: a genuinely new acknowledgement after a pre-drain read still gets its confirmation GET. Retained settlements and owned position writes still block the request.
     - It reuses the start GET's one-shot store capture and intake: capture before the request, then validate the dated item/episode, generation and row identity atomically, seeding a missing row cleanly. Ordinary server intake still skips unknown rows. A failed read is not absence, a failed save rolls back, and local edits, new acknowledgements or deletion (including absent → created → deleted) invalidate the old read. An unusable response creates no baseline or confirmation; a later drain may try again.
     - It changes durable progress only, never the loaded position, playback state, LastPlayed or the current resume decision. Admission belongs to the loaded session, not just its media key: stop, replacement, detach or quiescence prevents a new stale submission. Already-submitted store work is not cancelled and stays provenance-guarded. It adds no backend fence, conditional write, exactly-once or listening-time guarantee.
   - **Stale writes (#195, #380).** What keeps an old write from overwriting a newer position:
     - **Deferred PATCHes are fetched first.** The drain reads each dirty row's `GET /api/me/progress/:id` and merges it by ADR 0003 (#146) before sending. In a real conflict, a group whose server value is newer than its edit takes the server's value and sends nothing; a failed read sends nothing and leaves the row dirty for the drain's backed-off retry (`ProgressStaleDrainTests`).
     - **A late same-device request is neutralized by the server's takeover.** `/play` retires every open session of the same user and device, so a held `/sync` or `/close` for a session this device has moved on from answers 404 if the server looks the session up after the takeover. One the server applied before the takeover only set the position the newer session started from, and its lost response resends nothing (`ProgressLateCloseTests`).
     - **Resends must pass the admission rule (#195, #382).** A deferred report (today, point 3's queued `/close`) goes out again only if `ProgressSyncer.admitDeferredReport` admits it. The checks run in order before every resend:
       1. A detached or quiesced syncer skips.
       2. A different current session for the same media skips: its reports are newer.
       3. The server's progress is read and merged by ADR 0003, like the drain's pre-PATCH read. A failed read, offline included, skips without sending anything and keeps the close for a later drain.
       4. If the row's audio is no longer the report's own position (a later local edit, or another device's newer progress merged over it), it skips.
       5. A reply the merge didn't take (another item's, undated, or older than the stored server progress) decided nothing, so it skips like a failed read.

       Checks 1 and 2, that no position was queued since the read, and that the row hasn't changed in the store since then, run again after every later store call up to the send. The row check uses `LocalProgressStore.rowChangeStamp(for:)`, a per-row stamp the store moves on every committed edit, merge or deletion, readable without suspending. So a syncer that ended, a newer session for the media, a position saved meanwhile, or the row reset (marked not finished) or deleted (progress discarded) still skips.

       The position is identified by the audio edit time it committed with, which survives a relaunch, not by its in-process token. A skip never loses the position: the row stays dirty and the drain PATCHes it. A close skipped for a newer session or position is never resent: the drain settles it by its session's stored record, as it does a resend answered 404, so its listening time is carried only if it never counted (#383, `DeferredReportAdmissionTests`, `UndeliveredListeningTests.aSkippedCloseIsSettledByTheStoredRecord`). The only other resend is #381's once-only `/sync` for a still-open session whose lookup showed the earlier report unapplied.
     - **Remaining limits**, accepted:
       - Another device can write between the drain's GET and its PATCH or resent `/close` (the server has no conditional write).
       - The merge compares the device's edit time with the server's `lastUpdate`, so clock skew larger than the gap between two edits picks the wrong one (`clockSkewCanLoseANewerEdit`).
       - A group ADR 0003 shields because the server's value may be this device's own send or a side effect of one (a truncation flag, or audio matching an unacknowledged session report) keeps its edit without comparing times, so its PATCH can overwrite a newer value another device wrote meanwhile.
       - A `/sync` or `/close` whose session lookup passed before the takeover can still write after it: the server's `syncSession` awaits database reads between the lookup and the progress write without checking the session again. The test model looks up and writes atomically, so it can't show this.
       - Another device's sessions aren't retired by this device's `/play`, so a slow `/close` the server applies after the other device's newer report sets its position back (`aSlowCloseCanOverwriteAnotherDevice`).
       - A `/close` the server applied but answered with an error before removing the session (a 5xx after `syncSession`) is applied again by its resend, counting its listening time twice. One the server removed answers the resend with 404.

## Consequences

- **No private API.** Playback adds no App Review exposure beyond the CarPlay and audio entitlements.
- **Old servers are refused. This is a deliberate compatibility break with the legacy app.**
  - **Who:** users on servers below 2.26.0. The legacy app still supports them with the old non-expiring token and only a soft warning.
  - **What they see:** a blocking "This server runs Audiobookshelf X. Version 2.26.0 or newer is required." message at sign-in, with upgrade guidance.
  - **What they must do:** upgrade the server (2.26.0 shipped 2025-07-12; the current release is v2.37.2).
  - **Not yet settled:** the floor is provisional until the owner signs off (#48).
- **New failure mode.** Expired access tokens can no longer cause mid-playback 401s from Audiobookshelf, because streaming URLs carry no user token. Losing the session (restart, 36-hour idle, same-device takeover) is now the main failure mode. The engine handles it with the bounded recovery in Decision 3, so the engine carries more state: the saved position, the per-session listening deltas, and a persisted sync queue.
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

**Recovery and position tests.** These are engine unit tests with a stubbed player and API client. Where marked, #49 also runs them on a device.
- **Playlist 404 mid-play:** a 404 on the HLS playlist with the session gone (`GET /api/session/{id}` → 404) recovers through one rebuild. A new `/play` session is opened and the old id is never reused. Playback resumes within ≤ 0.5 s of the saved position at the same rate. On a device (#49), restart the server mid-play.
- **Segment 404 with the session alive:** re-seeks without opening a new session. A failed item is recreated with the same playlist URL.
- **`/sync` 404 while the session is loaded (#184):** the account's `PlaybackScope` opens a new session for the same media at the current position (`PlaybackCoordinator.replaceGoneSession`), playing only if playback was requested, and the 404'd report's listening time joins the new session (#383). Nothing happens if the session is no longer the loaded one or the scope retired (`PlaybackScopeSyncTests`).
- **401 on media or on `GET /api/session/{id}`:** the token is refreshed exactly once and recovery happens once. A second 401 in the same episode stops with an error and makes no further refresh or rebuild calls.
- **Three failed rebuild attempts:** surface the error with a Retry action after 1, 2 and 4 s backoff. There is no fourth `/play` call.
- **Network loss:** no attempts are spent while the path is unsatisfied. A retry happens immediately when the path becomes satisfied. The error appears after 5 minutes offline.
- **No double-counted listening time:**
  - Across a rebuild, the sum of `timeListened` sent to the old session's `/close` and the new session's `/sync` calls equals the played time, and stall or rebuild gaps add 0.
  - At 0.5× and 2×, 60 s of wall-clock playback reports 60 s. Seeks, skips, pauses and stalls add 0.
  - A `/close` whose 200 is lost (the server applied it), then retried and answered with 404: reconciliation finds the stored `timeListening` already includes the delta, and the delta is dropped rather than resent (`CloseReconciliationTests`, `ProgressLateCloseTests.aCloseIsResentOnlyWhileItCanStillCount`).
  - A `/close` that never reached the server (session lost on restart) has its delta carried once into the new session's `/sync` (same tests, and `aLateCloseIsRetiredByTheNextPlay`).
  - A `/sync` still out at the close that the server applies after it: the record holds its time but not the close's, so the close's delta is still carried once; with an earlier report's outcome unknown too, even after its lookup failed, nothing is counted twice (`CloseReconciliationTests.aSyncStillOutAtTheCloseIsAllowedFor`, `aSyncStillOutIsNotAllowedForAfterAFailedLookup`).
  - An undecidable reconciliation drops the delta, with no resend; so does a lookup that keeps failing, after six tries (`CloseReconciliationTests`).
  - Listening time a session can no longer send (#383): a `/sync` answered 404, and one that never reached the server after its session closed, are reported once by the media's next session, and one whose failure was ambiguous is dropped. A close that admission skips counts only if its session's stored record shows it never did (`UndeliveredListeningTests`).
  - Lost `/sync` responses:
    - When the server applied the `/sync` but the 200 was lost, `GET /api/session/:id` shows the delta applied. The snapshot is released and not resent, and the server total equals the time played.
    - When the request timed out before being applied, the snapshot is resent exactly once.
    - When the lookup fails, the snapshot is dropped and logged.
- **Position source:** the new session's server `currentTime` (deliberately older) is ignored, and the saved local position is used.
- **Now Playing:** elapsed time never decreases during a rebuild.
- **Serialized reporting:** two concurrent close or rebuild triggers for one session produce exactly one in-flight `/close`. A timed-out `/close` retried while playback continues resends the identical snapshot, and the time played meanwhile goes only into the new session. The server's total equals the time played.
- **Seek during recovery:**
  - A `stream_reset` or rebuild that arrives while a user seek is in flight ends at that seek's target, not at the older saved position.
  - A user seek issued mid-recovery wins over the recovery target.
  - A stale recovery seek completion does not overwrite the position.
- **Direct play to HLS fallback:** the fallback keeps the position and rate, and sends the old session's final `/close` before the transcode `/play`.

**Verified from source and SDK:**
- Every server behaviour cited in Context, with file paths at the commits listed.
- SDK header facts: no published header-fields key; `AVURLAssetOverrideMIMETypeKey` is available from iOS 17; `AVURLAssetHTTPUserAgentKey` is public. `AVURLAssetHTTPCookiesKey` is public too, but this ADR does not use it.
- The resource-loader API shape typechecks under Swift 6 for iOS and macOS 27.
- The MIME probe ran on macOS 27.2 only.

**Assumed, not verified:**
- `AVPlayer` seek and range behaviour against the public route.
- iOS results from `isPlayableExtendedMIMEType`.
- Resource-loader limits for HLS segments.
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
