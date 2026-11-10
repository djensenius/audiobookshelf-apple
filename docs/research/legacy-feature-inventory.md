# Audiobookshelf mobile parity inventory (legacy app)

## Pages / workflows
- Home/bookshelf: pages/index.vue, pages/bookshelf.vue, pages/bookshelf/index.vue — personalized shelves, continue listening, local shelves, disconnected messaging. components/bookshelf/{LazyBookshelf,Shelf}.vue; components/home/{BookshelfNavBar,BookshelfToolbar}.vue.
- Library & discovery: pages/bookshelf/{library,latest,authors,collections,playlists}.vue, series/{index,_id}.vue; pages/search.vue; components/cards/*, components/covers/*.
- Item details: pages/item/_id/index.vue (metadata, description, fullscreen cover, play/read/download, chapters/tracks/ebook files, more menu); pages/item/_id/_episode/index.vue; components/tables/{ChaptersTable,TracksTable}.vue, tables/ebook/*, tables/podcast/*, tables/collection/*; pages/media/_id/history.vue (playback history, jump to time).
- Collections/playlists: pages/collection/_id.vue, pages/playlist/_id.vue, pages/playlist.vue; components/modals/playlists/{AddCreateModal,PlaylistRow}.vue; tables/playlist/*.
- Podcasts: pages/bookshelf/add-podcast.vue, latest.vue; components/forms/NewPodcastForm.vue; modals/{PodcastEpisodesFeedModal,ItemDetailsModal}.vue; modals/rssfeeds/*.
- Offline: pages/downloads.vue, pages/downloading.vue, pages/localMedia/folders/{index,_id}.vue, localMedia/item/_id.vue; modals/{SelectLocalFolderModal,LibrariesModal}.vue, modals/downloads/DownloadItem.vue.
- Account/connection: pages/account.vue, pages/connect.vue, components/connection/ServerConnectForm.vue (multi-server, login, OIDC), modals/CustomHeadersModal.vue.
- Settings/stats/logs: pages/settings.vue; pages/stats.vue + components/stats/* (listening stats, sessions, daily chart, year in review x3); pages/logs.vue (view/copy/share).

## Player
components/app/{AudioPlayer,AudioPlayerContainer,Appbar,SideDrawer}.vue. Modals: Chapters, Bookmarks (+BookmarkItem), PlaybackSpeed, SleepTimer, SleepTimerLength, AutoSleepTimerRewindLength, Fullscreen, FullscreenCover, ItemMoreMenu, ItemDetails, Order, Filter, Dialog.
Requirements: compact/expanded + alternate view; transport; seek; chapters + chapter-track mode; bookmarks; speed; jump fwd/back; auto-rewind; sleep timer (duration / end of chapter; auto-sleep window; rewind; shake-to-reset + sensitivity; reset feedback; almost-done chime; fade-out); media-control seeking pref; lock screen/remote + Now Playing; queue/next episode; haptics. Cast/route not confirmed (AirPlay via AVRoutePickerView natively).
Native refs: ios/App/Shared/player/{AudioPlayer,PlayerHandler,PlayerProgress,AudioPlayerSleepTimer,AudioPlayerRateManager,DefaultedAudioPlayerRateManager,LegacyAudioPlayerRateManager}.swift, util/NowPlayingInfo.swift, PlayerEvents.swift, App/plugins/AbsAudioPlayer.swift.

## Settings (pages/settings.vue; ios/App/Shared/models/{DeviceSettings,PlayerSettings}.swift)
Defaults: auto-rewind on, alt view on, media-control seeking off, jumps 10s/10s, orientation unlocked, haptics LIGHT, en-us, cellular download/stream ALWAYS, sleep fade-out on; player rate 1.0, chapter-track mode on.
- Display: alt view, orientation lock, haptics, language, theme.
- Playback: jump amounts, auto-rewind, MP3 index seeking, media-control seeking.
- Sleep timer: shake reset + sensitivity, fade-out, reset feedback, almost-done chime, auto-sleep (start/end, length, rewind + length).
- Data: cellular download/stream policy.
- Android Auto (map to CarPlay design, don't copy).

## Offline native refs
ios/App/App/plugins/{AbsDownloader,AbsFileSystem,AbsDatabase,AbsLogger}.swift; Shared/models/download/{DownloadItem,DownloadItemPart}.swift; Shared/models/local/{LocalFile,LocalLibraryItem,LocalMediaProgress,LocalPodcastEpisode}.swift; Shared/models/server/MediaProgress.swift; Shared/util/{ApiClient,Database,DaoExtensions,Logger,SecureStorage,Store}.swift; App/{AppDelegate,MyViewController}.swift; Shared/models/ServerConnectionConfig.swift.

## Readers (deferrable)
components/readers/{Reader,EpubReader,PdfReader,ComicReader,MobiReader}.vue.

## Localization
strings/*.json: 42 locales, en-us.json has 381 top-level keys. languageCode device setting.

## Suggested work packages (≤20 files / ≤2000 lines each; split further)
1 Foundation/persistence/localization; 2 Server connection & account; 3 Download & local-media services; 4 Audio engine & progress; 5 Sleep timer & player prefs; 6 Player UI; 7 Navigation/app shell (iPhone/iPad/Duo/Mac adaptive); 8 Library browsing & search; 9 Item & podcast detail; 10 Playlists & collections editing; 11 Downloads/offline UI; 12 Stats/logs/year in review; 13 Readers; 14 Platform integrations (CarPlay, WidgetKit, App Intents, Mac, Duo); 15 Parity/accessibility/localization validation.
