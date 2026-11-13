# Parity checklist

This is a draft. It maps every row of the
[legacy feature inventory](research/legacy-feature-inventory.md) to its native
replacement, the issue or PR that tracks it, or a decision to drop it. Issue
[#111](https://github.com/djensenius/audiobookshelf-apple/issues/111) tracks
sign-off.

The statuses were taken from GitHub and the code at main `32febe3d`
(2026-11-12). They will go stale. Update a row when its issue closes.

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

**Playback.** Most player code is merged and tested at the package level, but
the app doesn't create a playback scope yet, so nothing plays. Every player row
is therefore In progress until
[#183](https://github.com/djensenius/audiobookshelf-apple/issues/183) (PR #481)
and [#184](https://github.com/djensenius/audiobookshelf-apple/issues/184) land.

## Pages and workflows

### Home and bookshelf

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Personalised shelves, continue listening | `HomeView`, `HomeShelvesView` | #62, PRs #295, #313 | Done | |
| Local (downloaded) shelves | `DownloadedShelfModel` (ABSAppModel) | #76, PR #455 | In progress (#76) | The model is merged; the app doesn't use it yet. |
| Disconnected messaging | `ConnectionBannerModel`, `ServerActionAvailability` (ABSAppModel) | #76, PR #455 | In progress (#76) | As above. |
| `BookshelfNavBar`, `BookshelfToolbar` | `MainTabView`, `LibraryPickerHeader`, `LibraryToolbar` | #44 | In progress (#44) | The shell issue stays open for #183, #184 and its manual checks. |

### Library and discovery

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `bookshelf/library.vue` | `LibraryView` | #63 | Done | Sort, filter and infinite scroll. |
| `bookshelf/latest.vue` | `LatestView` | #70 | Done | |
| `bookshelf/authors.vue` | `AuthorsView`, `AuthorDetailView` | #64 | Done | |
| `bookshelf/collections.vue` | `CollectionsView` | #71 | Done | |
| `bookshelf/playlists.vue` | `PlaylistsView` | #71 | Done | |
| `series/index.vue`, `series/_id.vue` | `SeriesView`, `SeriesDetailView` | #64 | Done | Download Series is #389 (PR #487 open). |
| `search.vue` | `SearchView` | #65 | Done | |
| `components/cards/*` | ABSUI item display kit (cards, rows, shelves) | #220 | Done | |
| `components/covers/*` | `CoverView` | #43 | Done | |

### Item details

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Metadata, description, fullscreen cover | `ItemDetailView`, `ItemDetailContent` | #66 | In progress (#66) | Open for the manual Play check. |
| Play | `ItemDetailContent` | #183 | In progress (#183) | The button stays disabled until #183 supplies `playItem`. |
| Read | — | #101, PR #474 | In progress (#101) | |
| Download | — | #75 | Not started (#75) | `isDownloadAvailable` is hard-coded to false. |
| `ChaptersTable`, `TracksTable`, `tables/ebook/*` | `ItemDetailTables` | #67, #341 | Done | |
| More menu | `ItemDetailMoreMenu`, ABSUI `ItemActionMenu` | #67, #342, #397 | Done | |
| `item/_id/_episode/index.vue` | `EpisodeDetailView` | #69 | Done | |
| `tables/podcast/*` | `PodcastDetailView` | #68 | Done | |
| `tables/collection/*` | `GroupDetailView` | #71 | Done | |
| `media/_id/history.vue` (playback history, jump to time) | `PlaybackHistoryView` | #61, #284 | In progress (#284) | The view exists, but `PlaybackHistoryDestination` is still a stub. |

### Collections and playlists

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `collection/_id.vue`, `playlist/_id.vue`, `tables/playlist/*` | `GroupDetailView` | #71 | Done | |
| `playlist.vue` | `PlaylistsView` | #71 | Done | |
| `AddCreateModal`, `PlaylistRow` | `AddToPlaylistSheet` | #93 | Done | |
| Playlist editing | `PlaylistEditSheet` | #93 | Done | |
| Play all | — | #354 | Not started (#354) | Plays through the queue. |

### Podcasts

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `add-podcast.vue`, `NewPodcastForm` | `AddPodcastView`, `NewPodcastForm` | #94 | Done | |
| `latest.vue` | `LatestView` | #70 | Done | |
| `PodcastEpisodesFeedModal` | `PodcastEpisodesFeedSheet` | #95 | Done | |
| `ItemDetailsModal` | `ItemDetailInfoSheet` | #342 | Done | |
| `modals/rssfeeds/*` | `RssFeedSheet` | #96, PRs #419, #463 | In progress (#96) | Open for live socket wiring and the manual admin check. |

### Offline

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `downloads.vue` | `DownloadsView` (stub) | #75 | Not started (#75) | |
| `downloading.vue` | `DownloadQueueView` (stub) | #75 | Not started (#75) | |
| `localMedia/item/_id.vue` | `LocalItemView` (stub) | #75 | Not started (#75) | |
| `modals/downloads/DownloadItem.vue` | — | #75 | Not started (#75) | |
| `localMedia/folders/*`, `SelectLocalFolderModal` | — | — | Dropped | Android-only: legacy hides it on iOS (`v-if="!isIos"`). Downloads use an app-managed folder ([#188](https://github.com/djensenius/audiobookshelf-apple/issues/188)); recorded in #75. |
| `LibrariesModal` | `LibraryPickerHeader` | #44 | Done | |

### Account and connection

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `account.vue` | `AccountView` | #92, PR #483 | Done | |
| `connect.vue`, `ServerConnectForm` | `ConnectFlowView`, `ServerAddressView`, `LoginView` | #40 | Done | |
| Multi-server | `ServerListView`, `AccountManager` | #38 | Done | Hardening follow-ups: #227, #312, #349. |
| OIDC | `WebAuthenticationSessionAuthenticator` | #31 | Done | |
| `CustomHeadersModal` | `CustomHeadersEditor` | #40 | Done | Streaming with custom headers: #148 (PR #433 merged, PR #473 open). Downloads with custom headers: #467, not started. |

### Settings, stats and logs

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `settings.vue` | `SettingsView` | #91 | Done | Settings rows are below. |
| `stats.vue`: listening stats, sessions, daily chart | `StatsView`, `DailyListeningChart` | #97 | Done | |
| Year in review (three variants) | `YearInReviewView` | #98, PRs #418, #436 | Done | User and server, with short and banner layouts. |
| `logs.vue` (view, copy, share) | `LogsView`, `LogExporter` | #99 | Done | |

## Player

The status rule in [Status legend](#status-legend) applies: rows whose code is
merged are In progress (#183) until the app can play.

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Compact (mini) player | `MiniPlayerView` | #183 | In progress (#183) | |
| Expanded player | `NowPlayingView`, `PlayerSlot` | #183 | In progress (#183) | |
| Alternate view | `SettingsView` | #91 | Done | A bookshelf card setting (`enableAltView`); see Settings. |
| Transport, seek | ABSUI `TransportControls`, `PlaybackCoordinator` | #183 | In progress (#183) | |
| Chapters | `ChaptersSheet` | #183 | In progress (#183) | |
| Chapter-track mode | `NowPlayingView` toggle | #183 | In progress (#183) | |
| Bookmarks | `BookmarksSheet`, `BookmarkStore` | #183 | In progress (#183) | |
| Speed | `PlaybackSpeedSheet` | #183 | In progress (#183) | |
| Jump forward and back | ABSUI `TransportControls` | #183 | In progress (#183) | |
| Auto-rewind | `PlaybackCoordinator` | #183 | In progress (#183) | |
| Sleep timer: duration, end of chapter | `SleepTimerSheet`, `SleepTimer` | #55, #183 | In progress (#183) | |
| Sleep timer: auto-sleep window, rewind, shake to reset and sensitivity, reset feedback, almost-done chime, fade-out | `SleepTimer` | #55, #147, #183 | In progress (#183) | |
| Media-control seeking | `NowPlayingController` | #183 | In progress (#183) | |
| Lock Screen, remote commands, Now Playing | `NowPlayingController`, `NowPlayingBridge` | #54, #183 | In progress (#183) | #54 closed; app wiring moved to #183. |
| Queue, next episode | `PlaybackQueue` | #60, #156 | In progress (#60) | The auto-advance core and queue composition (PR #445) are merged; the queue sheet (#156) is not started. |
| Haptics | ABSUI `Haptics` | #147 | In progress (#183) | |
| Cast and routes | ABSUI `RoutePicker` (AirPlay) | #183 | In progress (#183) | Cast was never confirmed in legacy; AirPlay only. |
| Close player | `MiniPlayerView`, `PlayerSlot` | #183 | In progress (#183) | |
| `Appbar`, `SideDrawer` | `MainTabView` | #44 | In progress (#44) | |
| `Order`, `Filter` modals | `LibrarySortMenu`, `LibraryFilterSheet` | #63 | Done | |
| `Dialog` modal | System alerts | — | Done | |
| `ItemMoreMenu`, `ItemDetails` modals | `ItemDetailMoreMenu`, `ItemDetailInfoSheet` | #67, #342 | Done | |
| `SleepTimerLength`, `AutoSleepTimerRewindLength` modals | `SleepTimerLengthPicker`, `SleepTimerSettingsSection` | #55, #91 | Done | |
| `Fullscreen` modal | `NowPlayingView` | #183 | In progress (#183) | |
| `FullscreenCover` modal | Cover viewer in `ItemDetailContent` | #66 | Done | |
| Native `AudioPlayer`, `PlayerHandler`, `PlayerProgress`, rate managers | ABSPlayback `AudioEngine`, `PlaybackCoordinator`, `ProgressSyncer` | #183, #184 | In progress (#183) | |
| Native `AudioPlayerSleepTimer` | `SleepTimer` | #55 | In progress (#183) | |
| Native `NowPlayingInfo`, `PlayerEvents`, `AbsAudioPlayer` | `NowPlayingController`, `PlaybackScope` | #183 | In progress (#183) | |

## Settings

The settings mapping is in [Settings](settings.md); this table records status.

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| Defaults | `AppSettings.Default` | #91 | Done | Matches the inventory, except that the theme follows the system. |
| Display: alternate view, haptics, theme | `SettingsView` | #91 | Done | |
| Display: orientation lock | — | — | Dropped | The system controls orientation ([ADR 0004](adr/0004-navigation.md), [Settings](settings.md)). |
| Display: language | — | — | Dropped | Replaced by the system per-app language ([Settings](settings.md)). |
| Playback: jump amounts, auto-rewind, MP3 index seeking, media-control seeking | `SettingsView` | #91 | Done | |
| Sleep timer settings | `SleepTimerSettingsSection` | #91 | Done | |
| Data: cellular download and stream policy | `SettingsView` | #91 | Done | |
| Android Auto | — | #79, #80, #81 | Dropped | Replaced by a CarPlay design ([Settings](settings.md)). CarPlay is In progress: `CarPlaySceneDelegate` is a stub; the browse tree (PR #440) is merged. |

## Offline native references

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `AbsDownloader` | `DownloadEngine` | #72 | Done | Background `URLSession`. |
| `AbsFileSystem` | `DownloadLayout` | #188 | Done | |
| `AbsDatabase`, `Database`, `DaoExtensions`, `Store` | ABSData `DataStack`, `SchemaV1`, store actors | #36, #37 | Done | |
| `AbsLogger`, `Logger` | ABSCore `Log`, `LogExporter` | #27 | Done | |
| `DownloadItem`, `DownloadItemPart` | `DownloadRecord`, `DownloadPart` | #73 | In progress (#73) | `DownloadManager` is merged; PR #500 is open. |
| `LocalFile`, `LocalLibraryItem`, `LocalPodcastEpisode` | `LocalFile`, `LocalLibraryItem`, `LocalItemStore` | #73 | In progress (#73) | |
| `LocalMediaProgress` | `LocalMediaProgress`, `LocalProgressStore` | #74, PR #496 | In progress (#74) | Local playback and offline sync. |
| `MediaProgress` | ABSCore `MediaProgress` | #25 | Done | |
| `ApiClient` | ABSAPI `APIClient` | #29 | Done | |
| `SecureStorage` | `KeychainStore` | #154 | Done | |
| `ServerConnectionConfig` | `ServerConnectionRecord` | #38 | Done | |
| `AppDelegate`, `MyViewController` | `AudiobookshelfApp`, `AppEnvironment` | #44 | In progress (#44) | Offline launch is #76. |

## Readers

| Legacy | Native | Tracking | Status | Notes |
| --- | --- | --- | --- | --- |
| `Reader.vue` | — | #101, PR #474 | In progress (#101) | |
| `EpubReader.vue` | `EPUBWebView` | #104, PRs #456, #457, #458, #475 | In progress (#104) | Not reachable until #101 lands. |
| `PdfReader.vue` | `PDFReaderView` | #102, PR #452 | In progress (#102) | Not reachable until #101 lands. |
| `ComicReader.vue` (CBZ) | `ComicArchive` | #105, PR #447 | In progress (#105) | The view is PR #477. |
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

These legacy features have no native code and no issue:

- **Total track.** The player menu option (`useTotalTrack`) shows the total
  track alongside the chapter track.
- **Scale elapsed time by speed.** The player menu option
  (`scaleElapsedTimeBySpeed`) shows times adjusted for playback speed.
- **Lock player.** The player menu option (`lockUi`) hides the jump and chapter
  controls and the scrubber cursor.

All three are in `components/app/AudioPlayer.vue` in the legacy app.

## Sign-off

These steps stay manual.

- [ ] Manual regression pass on TestFlight build ___ on iPhone.
- [ ] Manual regression pass on TestFlight build ___ on iPad.
- [ ] Manual regression pass on TestFlight build ___ on iPhone Duo.
- [ ] Manual regression pass on TestFlight build ___ on Mac.
- [ ] Manual regression pass on TestFlight build ___ with CarPlay.
- [ ] No open P0 or P1 bugs.
- [ ] Owner approval.
