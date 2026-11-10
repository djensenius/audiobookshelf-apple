# Audiobookshelf server API usage inventory (from legacy app; partial)

Paths are relative to the legacy checkout root (same files exist in audiobookshelf-apple).
JS requests: plugins/nativeHttp.js, plugins/axios.js. Swift: ios/App/Shared/util/ApiClient.swift. Bearer auth + refresh-token handling.

| Method | Path | Use / reference |
|---|---|---|
| GET | /api/authorize | connect/authorize; components/connection/ServerConnectForm.vue:923 |
| POST | /logout | store/user.js:158 |
| POST | /auth/refresh (x-refresh-token header) | token refresh; nativeHttp.js, axios.js, ApiClient.swift |
| GET | /ping | ApiClient.swift |
| GET | /api/libraries | store/libraries.js:80 |
| GET | /api/libraries/:id?include=filterdata | store/libraries.js:44 |
| GET | /api/libraries/:id/personalized?minified=1&include=rssfeed,numEpisodesIncomplete | pages/bookshelf/index.vue:245 |
| GET | /api/libraries/:id/search?q= | pages/search.vue:125 |
| GET | /api/libraries/:id/recent-episodes?limit=50&page= | pages/bookshelf/latest.vue:65 |
| GET | /api/libraries/:id/authors | pages/bookshelf/authors.vue:39 |
| GET | /api/libraries/:id/:entityPath?… (dynamic query) | components/bookshelf/LazyBookshelf.vue:183; pages/bookshelf/series/_id.vue:72 |
| GET | /api/items/:id[?expanded=1&include=rssfeed] | pages/item/_id/index.vue:761 |
| GET | /api/series/:id | pages/bookshelf/series/_id.vue:12 |
| GET | /api/collections/:id | pages/collection/_id.vue:41 |
| GET | /api/playlists/:id | pages/playlist/_id.vue:41 |
| GET | /api/libraries/:id/playlists | components/modals/playlists/AddCreateModal.vue:113 |
| POST | /api/playlists | AddCreateModal.vue:188 |
| POST | /api/playlists/:id/batch/add, /batch/remove {items} | AddCreateModal.vue:139,157 |
| DELETE | /api/playlists/:id/item/:itemId | components/modals/ItemMoreMenuModal.vue:492 |
| GET | /api/search/podcast?term= | pages/bookshelf/add-podcast.vue:106 |
| POST | /api/podcasts/feed {rssFeed} | add-podcast.vue:91,122 |
| POST | /api/podcasts | components/forms/NewPodcastForm.vue:144 |
| GET | /api/podcasts/:id/clear-queue | components/tables/podcast/EpisodesTable.vue:255 |
| POST | /api/podcasts/:id/download-episodes | components/modals/PodcastEpisodesFeedModal.vue:100 |
| DELETE | /api/podcasts/:id/episode/:episodeId?hard=1 | pages/item/_id/_episode/index.vue:585 |
| GET | /api/me/progress/:itemId[/:episodeId] | components/app/AudioPlayerContainer.vue:329 |
| PATCH | /api/me/progress/:itemId[/:episodeId] | readers/EpubReader.vue:176; ItemMoreMenuModal.vue:330,361 |
| DELETE | /api/me/progress/:progressId | ItemMoreMenuModal.vue:385 |
| POST/PATCH/DELETE | /api/me/item/:itemId/bookmark[/:time] | components/modals/BookmarksModal.vue:114,129,148 |
| GET | /api/me/listening-stats | pages/stats.vue:109 |
| GET | /api/me/stats/year/:year | components/stats/YearInReview.vue:265 |
| GET | /api/stats/year/:year | components/stats/YearInReviewServer.vue:244 |
| POST | /api/feeds/:entityType/:entityId/open | components/modals/rssfeeds/RssFeedModal.vue:152 |
| POST | /api/feeds/:feedId/close | RssFeedModal.vue:170 |
| POST | /api/emails/send-ebook-to-device | ItemMoreMenuModal.vue:473 |
| PATCH | /api/items/:id/ebook/:ino/status | components/tables/ebook/EbookFilesTable.vue:84 |
| GET | /api/items/:id/ebook[/:ino] | components/readers/Reader.vue:332,334 |
| GET | /api/items/:id/file/:ino[?token=] | stream; ios/App/Shared/player/AudioPlayer.swift:568,576 |
| GET | /api/items/:id/file/:ino/download | ios/App/App/plugins/AbsDownloader.swift:406,454 |
| GET | /api/items/:id/cover | AbsDownloader.swift:421; NowPlayingInfo.swift:29,31 |
| POST | api/session/:id/sync, api/session/local, api/session/local-all | ApiClient.swift:488–626 |
| POST | play session (caller-supplied endpoint, decodes PlaybackSession) | ApiClient.swift — trace `/api/items/:id/play[/:episodeId]` in store/plugins |

Socket.IO (plugins/server.js): path `<server pathname>/socket.io`, transports websocket only, upgrade:false, reconnectionDelayMax 15000; on connect emit `auth` with access token. Events: connect, disconnect, init, auth_failed, user_updated, user_item_progress_updated (payload.data), playlist_added; reconnect_attempt/error/failed.

OIDC: ServerConnectForm.vue (client_id, scope, state, redirect_uri, code, error). PKCE/redirect scheme still to be traced.

Version gates: image URLs need ?token for servers < 2.17 (store/index.js); Swift version compare helper in ios/App/Shared/util/Store.swift; min-version check in plugins/init.client.js.
