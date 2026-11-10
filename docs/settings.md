# Settings

The Settings screen (`Audiobookshelf/Features/Settings/`, issue #91) ports the legacy
`pages/settings.vue`. Most controls bind directly to `AppSettings` (ABSCore, App Group
`UserDefaults`); `SettingsViewModel` (ABSAppModel) handles only the derived ones (the
inverted bookshelf toggle, length presets and custom minutes, auto sleep times as dates).
Either way every change is written to `AppSettings` and applies live in every scene, the
CarPlay scene and extensions. On iOS the screen is pushed from the app; on macOS it is the
app's `Settings` scene.

Legacy played a haptic each time any setting was saved. The new screen plays one only when
the haptic feedback setting itself changes, so the user feels the strength they picked.

**Mac exception:** the Settings window keeps the native grouped form. The themed screen
and row backgrounds are iOS only, so the Black theme looks like Dark there.

## Decision: dropped legacy settings

These legacy settings are not ported:

- **Orientation lock** (`lockOrientation`). iPhone Duo and iPad windows resize when the
  device folds or the user resizes them, and the app adapts to size classes instead of
  orientation ([ADR 0004](adr/0004-navigation.md)). Locking orientation conflicts with that,
  and the iOS legacy app already hid it.
- **In-app language picker** (`languageCode`). The app uses the system's per-app language.
  The Language row shows the current language and, on iOS, opens the app's page in the
  Settings app (`UIApplication.openSettingsURLString`); iOS shows the Language option there
  only once the user has more than one preferred language. macOS has no supported URL for
  its per-app language list, so the row explains where to find it (System Settings >
  General > Language & Region > Applications).
- **Android Auto options** (`androidAutoBrowseLimitForGrouping`,
  `androidAutoBrowseSeriesSequenceOrder`). There is no Android app. CarPlay browsing is
  designed separately (P5) rather than copied from these options.

## Where each legacy setting went

| Legacy setting | Settings screen | Notes |
| --- | --- | --- |
| `enableAltView` | Display: Use bookshelf view | Inverted, as in legacy (`enableBookshelfView`). It only sets the card style (title and author under the cover, no shelf rows). Grid or list is the per-library `viewMode` in `libraryViewPreferences`, chosen from the library toolbar, not from Settings. |
| `lockOrientation` | Dropped | See above. |
| `hapticFeedback` | Display: Haptic feedback | Only on devices that can play haptics (`CHHapticEngine.capabilitiesForHardware().supportsHaptics`): iPhone, not iPad or Mac. Plays the chosen strength when changed. |
| `languageCode` | Dropped | See above; replaced by the Language row. |
| theme (`localStore`) | Display: Theme | Adds System, the new default, before Light, Dark and Black. |
| `jumpBackwardsTime`, `jumpForwardTime` | Playback | Legacy options 5, 10, 15, 30, 60, 120 and 300 s; a stored value outside them is listed too. |
| `disableAutoRewind` | Playback | |
| `enableMp3IndexSeeking` | Playback | Android only in legacy; now on every platform. |
| `allowSeekingOnMediaControls` | Playback | Enables seeking from the Now Playing controls (Lock Screen, Control Center; [ADR 0006](adr/0006-now-playing.md)). |
| `disableShakeToResetSleepTimer`, `shakeSensitivity` | Sleep timer | iOS only (needs a motion sensor). Sensitivity shows while shake to reset is on. |
| `disableSleepTimerFadeOut` | Sleep timer | |
| `disableSleepTimerResetFeedback` | Sleep timer | Only on devices that can play haptics, like Haptic feedback. |
| `enableSleepTimerAlmostDoneChime` | Sleep timer | |
| `autoSleepTimer`, `autoSleepTimerStartTime`, `autoSleepTimerEndTime` | Auto sleep timer | Warns when start and end are equal (the window would be empty). An end before the start runs past midnight. |
| `sleepTimerLength` | Auto sleep timer: Sleep timer | The length the auto sleep timer starts, shown while it is on, as in legacy. Presets 5–90 min, end of chapter, or a custom 1–1440 min. |
| `autoSleepTimerAutoRewind`, `autoSleepTimerAutoRewindTime` | Auto sleep timer | Length presets 5–90 min or a custom 1–1440 min. |
| `downloadUsingCellular`, `streamingUsingCellular` | Data | Low Data Mode counts as metered; on a Mac, so do expensive paths such as hotspots (`NetworkPolicy`). |
| `androidAutoBrowseLimitForGrouping`, `androidAutoBrowseSeriesSequenceOrder` | Dropped | See above. |
| `playbackRate`, `chapterTrack` (`PlayerSettings`) | Not on this screen | Set from the player, as in legacy; stored in `AppSettings`. |

`AppSettings.lastLibraryIDs` is native-only navigation state and has no control.

`AppSettings.libraryViewPreferences` (`settings_libraryViewPreferences`) is native-only too and has
no Settings control. It stores each library's sort, filter, grid or list view mode and collapse
series as a small JSON string under the key `serverID|userID|libraryID`. Nothing removes an entry
when an account or connection is removed (like `lastLibraryIDs`); only `resetAll()` clears it.
