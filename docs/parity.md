# Parity checklist

This is a draft. It maps every row of the
[legacy feature inventory](research/legacy-feature-inventory.md) to its native
replacement, the issue or PR that tracks it, or a decision to drop it. It was
written for [#111](https://github.com/djensenius/audiobookshelf-apple/issues/111)
(PR #506) and is updated as issues close.

The statuses were taken from GitHub and the code at main `17ca60dc`
(2026-11-14). They will go stale. Update a row when its issue closes.

## Status legend

A status describes the feature as a user reaches it in the app, not the package
code behind it.

| Status | Meaning |
| --- | --- |
| Done | The issue is closed and the feature is reachable in the app. |
| In progress (#N) | Some code is merged or a PR is open, but the feature is incomplete or not wired into the app. |
| Not started (#N) | An open issue tracks it and the user-facing part has no code yet. |
| Dropped | Not carried over, for the stated reason. |
| Needs check | The status could not be confirmed from the code and issues. |

**Playback.** The app plays. `AppEnvironment` gives each signed-in account its
own `PlaybackScope`
([#183](https://github.com/djensenius/audiobookshelf-apple/issues/183), PR #481)
with progress sync
([#184](https://github.com/djensenius/audiobookshelf-apple/issues/184), PR #534),
and downloaded items play from their local files (#74, PR #594). The
Now Playing runtime check on devices is still open under #44.

## Pages and workflows

### Home and bookshelf

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Personalised shelves, continue listening | `HomeView`, `HomeShelvesView` | #62, PRs #295, #313 | Done | |
| Local (downloaded) shelves | `DownloadedShelfModel` (ABSAppModel), `HomeView` | #76, PRs #455, #509, #546, #549, #588, #595 | Done | Home shows the downloaded shelves and the disconnected state. Manual checks are in #210. |
| Disconnected messaging | `ConnectionBannerModel`, `ServerActionAvailability` (ABSAppModel), `ConnectionBannerHost`, `ConnectionIndicatorToolbar` | #76, PRs #455, #509, #588, #595 | Done | The banner, the toolbar indicator (#595, part of #59) and offline gating of server-only menu actions are in the app. Manual checks are in #210. |
| `BookshelfNavBar`, `BookshelfToolbar` | `MainTabView`, `LibraryPickerHeader`, `LibraryToolbar` | #44 | In progress (#44) | #183 and #184 are closed; the shell issue stays open for its manual checks. |

### Library and discovery

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `bookshelf/library.vue` | `LibraryView` | #63 | Done | Sort, filter and infinite scroll. |
| `bookshelf/latest.vue` | `LatestView` | #70 | Done | |
| `bookshelf/authors.vue` | `AuthorsView`, `AuthorDetailView` | #64 | Done | |
| `bookshelf/collections.vue` | `CollectionsView` | #71 | Done | |
| `bookshelf/playlists.vue` | `PlaylistsView` | #71 | Done | |
| `series/index.vue`, `series/_id.vue` | `SeriesView`, `SeriesDetailView` | #64 | Done | Download Series is #389 (PR #487). |
| `search.vue` | `SearchView` | #65 | Done | |
| `components/cards/*` | ABSUI item display kit (cards, rows, shelves) | #220 | Done | |
| `components/covers/*` | `CoverView` | #43 | Done | |

### Item details

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Metadata, description, fullscreen cover | `ItemDetailView`, `ItemDetailContent` | #66 | In progress (#66) | Open for the manual Play check. |
| Play | `ItemDetailContent` | #183 | Done | #183 supplies `playItem`. Play links ask before playing (#577, PR #591). |
| Read | `ReaderContainer` | #101, PRs #474, #596 | In progress (#101) | The Read button opens the reader; unsupported formats offer Open In. |
| Download | `ItemDownloadButton` | #75, PRs #576, #582, #602 | In progress (#75) | Books and podcast episodes download from their detail and episode rows. Cards and list rows mark downloaded items (PR #602, part of #106). |
| `ChaptersTable`, `TracksTable`, `tables/ebook/*` | `ItemDetailTables` | #67, #341 | Done | |
| More menu | `ItemDetailMoreMenu`, ABSUI `ItemActionMenu` | #67, #342, #397 | Done | |
| `item/_id/_episode/index.vue` | `EpisodeDetailView` | #69 | Done | |
| `tables/podcast/*` | `PodcastDetailView` | #68 | Done | |
| `tables/collection/*` | `GroupDetailView` | #71 | Done | |
| `media/_id/history.vue` (playback history, jump to time) | `PlaybackHistoryView`, `PlaybackHistoryDestination` | #61, #284 | Done | |

### Collections and playlists

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `collection/_id.vue`, `playlist/_id.vue`, `tables/playlist/*` | `GroupDetailView` | #71 | Done | |
| `playlist.vue` | `PlaylistsView` | #71 | Done | |
| `AddCreateModal`, `PlaylistRow` | `AddToPlaylistSheet` | #93 | Done | |
| Playlist editing | `PlaylistEditSheet` | #93 | Done | |
| Play all | `GroupDetailView` | #354, PRs #542, #561 | Done | Plays through the queue. |

### Podcasts

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `add-podcast.vue`, `NewPodcastForm` | `AddPodcastView`, `NewPodcastForm` | #94 | Done | |
| `latest.vue` | `LatestView` | #70 | Done | |
| `PodcastEpisodesFeedModal` | `PodcastEpisodesFeedSheet` | #95 | Done | |
| `ItemDetailsModal` | `ItemDetailInfoSheet` | #342 | Done | |
| `modals/rssfeeds/*` | `RssFeedSheet` | #96, PRs #419, #463, #503, #605 | In progress (#96) | The sheet and its entry points are in the app. Live opens and closes reach an open sheet (#601, PR #605); the manual admin check is still open. |

### Offline

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `downloads.vue` | `DownloadsView` | #75, PR #501 | In progress (#75) | |
| `downloading.vue` | `DownloadQueueView` | #75, PR #501 | In progress (#75) | |
| `localMedia/item/_id.vue` | `LocalItemView`, `LocalItemDetailView` | #75, PR #531 | In progress (#75) | |
| `modals/downloads/DownloadItem.vue` | `DownloadQueueRow` | #75, PR #501 | In progress (#75) | |
| `localMedia/folders/*`, `SelectLocalFolderModal` | — | — | Dropped | Android-only: legacy hides it on iOS (`v-if="!isIos"`). Downloads use an app-managed folder ([#188](https://github.com/djensenius/audiobookshelf-apple/issues/188)); recorded in #75. |
| `LibrariesModal` | `LibraryPickerHeader` | #44 | Done | |

### Account and connection

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `account.vue` | `AccountView` | #92, PR #483 | Done | |
| `connect.vue`, `ServerConnectForm` | `ConnectFlowView`, `ServerAddressView`, `LoginView` | #40 | Done | |
| Multi-server | `ServerListView`, `AccountManager` | #38 | Done | Hardening follow-ups: #227, #312, #349. |
| OIDC | `WebAuthenticationSessionAuthenticator` | #31 | Done | |
| `CustomHeadersModal` | `CustomHeadersEditor` | #40 | Done | Streaming with custom headers: #148 (PRs #433, #473). Downloads with custom headers: #467, foreground session done; the "only while the app is open" notice is on Downloads, the Download Series confirmation and the item and episode download buttons (PR #593). |

### Settings, stats and logs

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `settings.vue` | `SettingsView` | #91 | Done | Settings rows are below. |
| `stats.vue`: listening stats, sessions, daily chart | `StatsView`, `DailyListeningChart` | #97 | Done | |
| Year in review (three variants) | `YearInReviewView` | #98, PRs #418, #436 | Done | User and server, with short and banner layouts. |
| `logs.vue` (view, copy, share) | `LogsView`, `LogExporter` | #99 | Done | |

## Player

The status rule in [Status legend](#status-legend) applies. #183 and #184 are
closed and the app plays, so a player row is Done unless its own issue is still
open or the app doesn't wire it in yet.

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Compact (mini) player | `MiniPlayerView` | #183 | Done | |
| Expanded player | `NowPlayingView`, `PlayerSlot` | #183 | Done | |
| Alternate view | `SettingsView` | #91 | Done | A bookshelf card setting (`enableAltView`); see Settings. |
| Transport, seek | ABSUI `TransportControls`, `PlaybackCoordinator` | #183 | Done | |
| Chapters | `ChaptersSheet` | #183 | Done | |
| Chapter-track mode | `NowPlayingView` toggle | #183 | Done | |
| Bookmarks | `BookmarksSheet`, `BookmarkStore` | #183 | Done | |
| Speed | `PlaybackSpeedSheet` | #183 | Done | |
| Jump forward and back | ABSUI `TransportControls` | #183 | Done | |
| Auto-rewind | `PlaybackCoordinator` | #183 | Done | |
| Sleep timer: duration, end of chapter | `SleepTimerSheet`, `SleepTimer` | #55, #183, #600, PR #604 | Done | Each account's playback scope creates a timer (#600, PR #604). The player, macOS menu, CarPlay and App Intent controls use it. Manual checks are in #210. |
| Sleep timer: auto-sleep window, rewind, shake to reset and sensitivity, reset feedback, almost-done chime, fade-out | `SleepTimer` | #55, #147, #183, #600, PR #604 | Done | Each account's playback scope creates a timer (#600, PR #604). Manual checks are in #210. |
| Media-control seeking | `NowPlayingController` | #183 | Done | |
| Lock Screen, remote commands, Now Playing | `NowPlayingController`, `NowPlayingBridge` | #54, #183 | Done | #54 and #183 are closed. The runtime check on devices is part of #44. |
| Queue, next episode | `PlaybackQueue` | #60, #156 | In progress (#60) | The auto-advance core and queue composition (PR #445) are merged, and so are the queue sheet, the queue inspector and "Play next" / "Add to queue" (#156, still open). Background-safe auto-advance is wired (#160, PR #554; #587, PR #590). The iPhone Duo player's Up Next pane shows the queue (#84). |
| Haptics | ABSUI `Haptics` | #147 | Done | The player's transport controls and the sleep timer's reset feedback use the haptics setting. |
| Cast and routes | ABSUI `RoutePicker` (AirPlay) | #183 | Done | Cast was never confirmed in legacy; AirPlay only. |
| Close player | `MiniPlayerView`, `PlayerSlot` | #183 | Done | |
| Total track, scale elapsed time by speed, lock player | `PlayerOptionsMenu` | #505, PR #526 | Done | Listed under Gaps found in the first draft. |
| `Appbar`, `SideDrawer` | `MainTabView` | #44 | In progress (#44) | |
| `Order`, `Filter` modals | `LibrarySortMenu`, `LibraryFilterSheet` | #63 | Done | |
| `Dialog` modal | System alerts | — | Done | |
| `ItemMoreMenu`, `ItemDetails` modals | `ItemDetailMoreMenu`, `ItemDetailInfoSheet` | #67, #342 | Done | |
| `SleepTimerLength`, `AutoSleepTimerRewindLength` modals | `SleepTimerLengthPicker`, `SleepTimerSettingsSection` | #55, #91, #600, PR #604 | Done | |
| `Fullscreen` modal | `NowPlayingView` | #183 | Done | |
| `FullscreenCover` modal | Cover viewer in `ItemDetailContent` | #66 | Done | |
| Native `AudioPlayer`, `PlayerHandler`, `PlayerProgress`, rate managers | ABSPlayback `AudioEngine`, `PlaybackCoordinator`, `ProgressSyncer` | #183, #184 | Done | |
| Native `AudioPlayerSleepTimer` | `SleepTimer` | #55, #600, PR #604 | Done | |
| Native `NowPlayingInfo`, `PlayerEvents`, `AbsAudioPlayer` | `NowPlayingController`, `PlaybackScope` | #183 | Done | |

## Settings

The settings mapping is in [Settings](settings.md); this table records status.

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Defaults | `AppSettings.Default` | #91 | Done | Matches the inventory, except that the theme follows the system. |
| Display: alternate view, haptics, theme | `SettingsView` | #91 | Done | |
| Display: orientation lock | — | — | Dropped | The system controls orientation ([ADR 0004](adr/0004-navigation.md), [Settings](settings.md)). |
| Display: language | — | — | Dropped | Replaced by the system per-app language ([Settings](settings.md)). |
| Playback: jump amounts, auto-rewind, MP3 index seeking, media-control seeking | `SettingsView` | #91 | Done | |
| Sleep timer settings | `SleepTimerSettingsSection` | #91, #600, PR #604 | Done | Each account's timer uses the saved settings (#600, PR #604). |
| Data: cellular download and stream policy | `SettingsView` | #91 | Done | |
| Android Auto | — | #79, #80, #81 | Dropped | Replaced by a CarPlay design ([Settings](settings.md)). The CarPlay scene shows the Continue, Library, Latest and Downloads tabs (PRs #544, #567, #606) and the Now Playing buttons, including the sleep timer (PRs #564, #604). #80 is closed, with manual checks in #210. #79 and #81 are open, and the CarPlay entitlement isn't granted yet. |

## Offline native references

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `AbsDownloader` | `DownloadEngine` | #72 | Done | Background `URLSession`. |
| `AbsFileSystem` | `DownloadLayout` | #188 | Done | |
| `AbsDatabase`, `Database`, `DaoExtensions`, `Store` | ABSData `DataStack`, `SchemaV1`, store actors | #36, #37 | Done | |
| `AbsLogger`, `Logger` | ABSCore `Log`, `LogExporter` | #27 | Done | |
| `DownloadItem`, `DownloadItemPart` | `DownloadRecord`, `DownloadPart` | #73, PR #500 | Done | |
| `LocalFile`, `LocalLibraryItem`, `LocalPodcastEpisode` | `LocalFile`, `LocalLibraryItem`, `LocalItemStore` | #73 | Done | |
| `LocalMediaProgress` | `LocalMediaProgress`, `LocalProgressStore` | #74, PRs #496, #512, #594, #603 | Done | Downloaded items play from their local files with local sessions, which upload on reconnect. Downloaded ebooks keep their reading progress linked to the download (PR #603). Manual checks are in #210. |
| `MediaProgress` | ABSCore `MediaProgress` | #25 | Done | |
| `ApiClient` | ABSAPI `APIClient` | #29 | Done | |
| `SecureStorage` | `KeychainStore` | #154 | Done | |
| `ServerConnectionConfig` | `ServerConnectionRecord` | #38 | Done | |
| `AppDelegate`, `MyViewController` | `AudiobookshelfApp`, `AppEnvironment` | #44 | In progress (#44) | Offline launch is #76. |

## Readers

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `Reader.vue` | `ReaderContainer` | #101, PRs #474, #596 | In progress (#101) | Reachable from Read; other formats offer Open In. |
| `EpubReader.vue` | `EPUBWebView` | #104, PRs #456, #457, #458, #475, #548, #583, #597 | In progress (#104) | Reachable from Read, with a table of contents, a gap over the Duo hinge and keep screen awake. |
| `PdfReader.vue` | `PDFReaderView` | #102, PRs #452, #510 | In progress (#102) | Reachable from Read. |
| `ComicReader.vue` (CBZ) | `ComicArchive`, `ComicReaderView` | #105, PRs #447, #477, #547 | In progress (#105) | Reachable from Read. |
| `ComicReader.vue` (CBR) | — | — | Dropped | [ADR 0008](adr/0008-readers.md), decision 4. |
| `MobiReader.vue` | — | — | Dropped | [ADR 0008](adr/0008-readers.md), decision 5. |

## Localisation

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `strings/*.json` (42 locales) | String Catalog | #22 | Done | See [Localization](localization.md). |
| Validation | `mise run strings:check` | #107, PRs #416, #446 | In progress (#107) | |
| `languageCode` setting | — | — | Dropped | Replaced by the system per-app language. |

The inventory's "Suggested work packages" section lists packages of work, not
features, so it has no rows here.

## Gaps found

None at this snapshot. The first draft listed three player menu options from
`components/app/AudioPlayer.vue` with no native code and no issue: total track
(`useTotalTrack`), scale elapsed time by speed (`scaleElapsedTimeBySpeed`) and
lock player (`lockUi`). They were tracked as #505 and are now in the Player
table.

## Sign-off

These steps stay manual.

- [ ] Manual regression pass on TestFlight build ___ on iPhone.
- [ ] Manual regression pass on TestFlight build ___ on iPad.
- [ ] Manual regression pass on TestFlight build ___ on iPhone Duo.
- [ ] Manual regression pass on TestFlight build ___ on Mac.
- [ ] Manual regression pass on TestFlight build ___ with CarPlay.
- [ ] No open P0 or P1 bugs.
- [ ] Owner approval.
