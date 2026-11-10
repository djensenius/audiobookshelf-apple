# 0006. Now Playing API

- Status: Accepted
- Date: 2026-11-09
- Issue: #47 (P2-01)

## Context

The player has to publish metadata and accept transport commands on these surfaces:

- the iOS Lock Screen and Control Center;
- AirPods and other headphones;
- Mac media keys and the Now Playing item in Control Center;
- CarPlay (`CPNowPlayingTemplate`).

iOS 27 and macOS 27 add the **NowPlaying framework**. Its `MediaSession` publishes an
`@Observable` model that conforms to `MediaSessionRepresentable` and returns typed
content (`BookContent`, `PodcastContent`), a `MediaPlaybackSnapshot` and a list of
`MediaCommand`s. The older **MediaPlayer** pair (`MPNowPlayingInfoCenter` and
`MPRemoteCommandCenter`) is still supported and not deprecated.

Apple's framework overview says:

> Don't mix the Now Playing framework with the `MPNowPlayingInfoCenter` and
> `MPRemoteCommandCenter` APIs from the MediaPlayer framework for local playback.
> Doing so results in undefined behavior.

So we must pick one API for every platform and for CarPlay, and enforce that choice.
The minimum OS is iOS 27.0 and macOS 27.0 (native, not Catalyst). The code uses
Swift 6 with complete strict concurrency, and the player is a `@MainActor`
`@Observable` engine in `ABSPlayback` ([architecture](../architecture.md)).

The legacy app uses MediaPlayer:

- [`ios/App/Shared/util/NowPlayingInfo.swift`](../../ios/App/Shared/util/NowPlayingInfo.swift)
  builds a `nowPlayingInfo` dictionary.
  - In "chapter track" mode, the title becomes the chapter title, the album title
    keeps the book title, and duration and elapsed time are relative to the chapter
    (lines 64–88).
  - The cover is fetched and wrapped in `MPMediaItemArtwork` (lines 49–62).
- [`ios/App/Shared/player/AudioPlayer.swift`](../../ios/App/Shared/player/AudioPlayer.swift)
  `setupRemoteTransportControls()` (lines 669–789) registers the commands:
  - play, pause and toggle;
  - skip forward and back, using the user's jump intervals;
  - next and previous **track**, which are remapped to jumps (AirPods double and
    triple press);
  - `changePlaybackPositionCommand`, enabled only when the
    `allowSeekingOnMediaControls` setting is on and offset by the chapter start;
  - `changePlaybackRateCommand` with `[0.5, 0.75, 1.0, 1.25, 1.5, 2]`.

The earlier research is in [platform-apis.md §3.1](../research/platform-apis.md#31-now-playing-which-api-to-use)
and [§2.5](../research/platform-apis.md#25-cpnowplayingtemplate-cpnowplayingtemplateh50118-cpnowplayingbuttonh13125).

## Decision drivers

1. **One API on iOS, macOS and CarPlay.** Apple says mixing the two is undefined
   behavior.
2. Native macOS support, with no per-platform publishing code.
3. Fits Swift 6 strict concurrency and the `@MainActor @Observable` player.
4. Audiobook features from the legacy app: chapter display, configurable skip
   intervals, rate, a user setting that disables scrubbing, and artwork.
5. CarPlay `CPNowPlayingTemplate` works without extra plumbing.
6. App Intents and Siri can link Now Playing content to our `AppEntity` types.
7. Mature and well documented, so there are fewer runtime surprises.

## Options considered

### Option 1: NowPlaying framework (`MediaSession`)

Make the player model conform to `MediaSessionRepresentable`. Return `BookContent`
or `PodcastContent`, a `MediaPlaybackSnapshot` and `[MediaCommand]`. Publish with
`MediaSession(model)` and `requestToBecomeApplicationPrimary()`.

- Pros:
  - The macOS and iOS 27.2 swiftinterfaces are identical apart from build flags
    (`diff` shows only lines 2–3). On macOS, the only things missing are
    `isSystemPrimary` and `requestToBecomeSystemPrimary()`, which are iOS-only.
  - Observation-driven. The framework observes the `@Observable` model and pushes
    updates itself, so we don't maintain a dictionary or poll a timer. The spike
    typechecks under Swift 6 with `-strict-concurrency=complete` without
    `assumeIsolated` or `@preconcurrency`.
  - Commands are `async throws` closures on a `@MainActor` protocol, so handlers
    call the player directly.
  - Typed content:
    - `BookContent` has `title`, `authorName`, `narratorName` and
      `chapter: (current:total:)`.
    - `PodcastContent` has `episodeTitle`, `showName` and `releaseDate`.
  - Artwork is an `async`, `@Sendable`, size-aware provider that returns `Data` or a
    `CGImage`. The same code works on both platforms.
  - App Intents: `_NowPlaying_AppIntents` adds `appEntityIdentifiers` to every
    content type.
  - Several sessions per app (book and podcast) and `.buffering` / `.interrupted`
    states are built in.
- Cons:
  - New in 27.0, so there is little field experience.
  - The docs don't match the SDK. The "Content types and metadata" article mentions
    `collectionID` and `serviceID`, but neither is in the 27.2 swiftinterface.
  - CarPlay docs still describe MediaPlayer:
    - `CPNowPlayingTemplate` "displays information from `MPNowPlayingInfoCenter` and
      `MPNowPlayingSession`".
    - `CPNowPlayingPlaybackRateButton` says "CarPlay uses `MPRemoteCommandCenter` to
      observe changes to the playback rate".

    The NowPlaying overview says it integrates with CarPlay, but nothing documents
    how the rate button behaves with this framework.
  - `BookContent` has **no separate slot for the book title alongside a chapter
    title**. Its only fields are `title`, `authorName`, `narratorName`, `chapter`
    and `genre`. The legacy chapter-track layout (chapter title over book title)
    can't be reproduced exactly.
  - The docs say that "unavailable commands still appear in the interface, but the
    system doesn't invoke their handler". To hide scrubbing, we have to leave out
    `seekToPosition`. `.enabled(false)` may still show a scrubber.
  - `MediaSession` is `@available(iOSApplicationExtension, unavailable)`. The spike
    confirmed this is a compile error with `-application-extension`.

### Option 2: MediaPlayer (`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`)

Port the legacy approach: an untyped `nowPlayingInfo` dictionary plus target-action
handlers on `MPRemoteCommandCenter.shared()`.

- Pros:
  - Mature. The CarPlay docs (`CPNowPlayingTemplate`,
    `CPNowPlayingPlaybackRateButton`) are written against it, and the legacy app
    proves the behavior in production.
  - Available on macOS since 10.12.2 (`MP_API(... macos(10.12.2) ...)` in
    `MPNowPlayingInfoCenter.h` and `MPRemoteCommandCenter.h`), with no deprecation
    markers in the 27.2 headers.
  - Rich chapter metadata: `MPMediaItemPropertyTitle` holds the chapter and
    `MPMediaItemPropertyAlbumTitle` the book. `MPNowPlayingInfoPropertyChapterNumber`
    and `…ChapterCount` are also available (`MPNowPlayingInfoCenter.h:112,115`).
  - Explicit seek switch: `changePlaybackPositionCommand.isEnabled`.
  - App Intents in 27.0: `MPNowPlayingInfoPropertyAppEntityIdentifiers`
    (`MPNowPlayingInfoCenter.h:194`) with `MPAppEntityIdentifier(entityIdentifier:)`
    from `_MediaPlayer_AppIntents`.
- Cons:
  - Untyped `[String: Any]` dictionary and global singletons. We would own throttling
    and elapsed-time bookkeeping again (legacy `NowPlayingInfo.update`).
  - Handlers are synchronous and return `MPRemoteCommandHandlerStatus`. Under Swift 6
    the spike had to use `MainActor.assumeIsolated` in each handler. That relies on
    main-thread delivery at runtime, which the compiler doesn't check and would
    trap if wrong.
  - Per-platform artwork: `MPMediaItemArtwork(boundsSize:requestHandler:)` takes a
    `UIImage` on iOS and an `NSImage` on macOS (`MPMediaItem.h:222,231`).
  - macOS needs `MPNowPlayingInfoCenter.playbackState` set by hand
    (`MPNowPlayingInfoCenter.h:70`), which adds a platform branch.
  - It is the legacy path for a 27-only app, and Apple's new sample code and
    content types target NowPlaying.

### Option 3: `MPNowPlayingSession` (MediaPlayer, per-`AVPlayer` session)

A variant of Option 2 where `automaticallyPublishesNowPlayingInfo` derives metadata
from `AVPlayer`.

- Pros:
  - Less manual elapsed-time and rate bookkeeping.
- Cons:
  - `MPNowPlayingSession.h:19` is `MP_UNAVAILABLE_BEGIN(watchos, macos)`, so it
    doesn't exist on macOS. That breaks driver 2, so we rejected this option without
    further spiking.

### Rejected outright: one API per platform, or both

Using NowPlaying on one platform and MediaPlayer on another doubles the code paths.
CarPlay runs inside the iOS app, so it would inherit whichever API iOS uses. Using
both on one platform is the undefined behavior Apple warns about. The spike shows
the **compiler does not stop either**: a single module that imports both modules and
uses both APIs typechecks cleanly (exit 0). That is why a lint rule is needed.

### Capability matrix

Evidence key:

- **T**: typechecked in the spike for iOS 27.0 simulator, iOS 27.0 device and
  macOS 27.0.
- **H**: read in the 27.2 SDK swiftinterface or header.
- **D**: stated in Apple documentation.
- **R?**: runtime behavior not verified. Nothing in this table was run on a device,
  simulator or car.

| Capability | NowPlaying (`MediaSession`) | MediaPlayer (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`) |
| --- | --- | --- |
| iOS Lock Screen and Control Center | Yes. `requestToBecomeSystemPrimary()` (iOS-only, foreground) makes it the system session. D, T, R? | Yes. D, T, R? |
| AirPods and headphones | "Connected accessories" (D). Commands: `togglePlayPause`, `next`, `previous`, `skipForward`/`skipBackward`. T, R? | Same command set. The legacy app remaps next/previous to jumps. D, T, R? |
| Mac media keys and Control Center | `MediaSession` is available on macOS 27. There is no system-primary API on macOS; app-primary only. H, T, R? | Available since macOS 10.12.2. Must set `playbackState` on macOS. H, T, R? |
| CarPlay `CPNowPlayingTemplate` | Overview claims CarPlay (D). CarPlay docs reference only MediaPlayer, and the rate-button state is undocumented. Template config is API-agnostic. T, **R? (gap)** | Documented path for the template and the rate button. D, T, R? |
| Chapter display | `BookContent.chapter = (current, total)`. Chapter title must replace the book title; there is no album or book field. H, T | `ChapterNumber`/`ChapterCount`, chapter in `Title`, book in `AlbumTitle`. H, T |
| Skip intervals | `skipForward(preferredIntervals:)` / `skipBackward(preferredIntervals:)`; the handler receives the interval. H, T | `skipForwardCommand.preferredIntervals`, `MPSkipIntervalCommandEvent.interval`. H, T |
| Rate | `changePlaybackRate(supported:)`, snapshot `.playing(rate:)`, `defaultPlaybackRate`. H, T | `changePlaybackRateCommand.supportedPlaybackRates`, `PlaybackRate` / `DefaultPlaybackRate` keys. H, T |
| Disable seeking | Leave out `seekToPosition`. `.enabled(false)` still "appears in the interface" (D). T, R? | `changePlaybackPositionCommand.isEnabled = false`. H, T, R? |
| Artwork | `Artwork(id:artworkProvider:)`: async, `@Sendable`, size-aware; `ArtworkRepresentation(data:)` or `(cgImage:)`. Same on both OSes. H, T | `MPMediaItemArtwork(boundsSize:requestHandler:)`: synchronous; `UIImage` on iOS, `NSImage` on macOS. H, T |
| App Intents bridging | `content.appEntityIdentifiers = [EntityIdentifier]` (`_NowPlaying_AppIntents`). H, T | `MPNowPlayingInfoPropertyAppEntityIdentifiers: [MPAppEntityIdentifier]` (27.0). H, T |
| Swift 6 strict concurrency | `@MainActor` protocol, `async throws` closures; no escape hatches. T | Needs `MainActor.assumeIsolated` in handlers (runtime main-thread assumption). T |
| App extensions | `MediaSession` unavailable (compile error verified). T | Usable, but not needed. H |

## Decision

**Use the NowPlaying framework (`MediaSession`) as the only Now Playing API on iOS,
macOS and CarPlay. Do not import MediaPlayer anywhere in the native app.**

Rules for the Now Playing implementation (P2-07 #54; CarPlay parts in P5-02 #79 and
P5-04 #81):

1. **One owner.** All NowPlaying code lives in
   `Packages/AudiobookshelfKit/Sources/ABSPlayback/NowPlaying/`, and its tests live
   in `Packages/AudiobookshelfKit/Tests/ABSPlaybackTests/NowPlaying/`.
   - `PlaybackCoordinator` (P2-06a #52), or a small adapter it owns, conforms to
     `MediaSessionRepresentable`.
   - Nothing else imports `NowPlaying` or `_NowPlaying_AppIntents`. That includes
     the app, its tests and the `AudiobookshelfWidgets` extension (P5-11a #88).
   - The UI, CarPlay and intents talk to the player, never to the session.
2. **Content.**
   - Books use `BookContent` with `chapter = (index + 1, count)`.
   - Podcast episodes use `PodcastContent`.
   - In chapter-track mode, `title` is the chapter title and `duration` and
     `elapsedTime` are relative to the chapter, matching the legacy app. The book
     title is not shown in that mode; this is a known gap, re-checked at runtime.
   - Set `appEntityIdentifiers` from an **injected closure**. `ABSPlayback` never
     imports the app or widget `AppEntity` types. It defines only the closure type
     and calls it. The composition root (`AppEnvironment` in the app, or the widget
     extension's equivalent) supplies the closure, which maps a `MediaKey` (ABSData)
     to the entity identifiers. The shape below typechecks for iOS 27.0 and
     macOS 27.0 under Swift 6 with a stub `MediaKey`; `key.rawValue` stands in for
     whatever accessor `MediaKey` exposes:

     ```swift
     // ABSPlayback/NowPlaying/ (imports AppIntents and _NowPlaying_AppIntents only)
     public typealias NowPlayingEntityIdentifiers = @Sendable (MediaKey) -> [EntityIdentifier]

     var content = BookContent(id: key.rawValue, title: title, authorName: author,
                               duration: .finite(duration), artwork: artwork)
     content.appEntityIdentifiers = entityIdentifiers(key)

     // App (or widget) composition root, which owns BookEntity / EpisodeEntity
     let entityIdentifiers: NowPlayingEntityIdentifiers = { key in
         [EntityIdentifier(for: BookEntity.self, identifier: key.rawValue)]
     }
     ```

     `EntityIdentifier` is `Sendable` (AppIntents swiftinterface), so the closure can
     be stored on the `@MainActor` session adapter and passed in through the
     `PlaybackCoordinator` (P2-06a #52) initializer.
3. **Commands.**
   - Commands: `play`, `pause`, `togglePlayPause`, and `skipForward`/`skipBackward`
     with the user's jump intervals.
   - The remote **next/previous track** commands jump forward and back by the same
     user intervals, as in the legacy app (`AudioPlayer.swift` lines 741–757). AirPods
     double and triple press send next and previous, so this keeps AirPods behaving
     as before. These commands do **not** change chapter.
   - Chapter navigation lives in the in-app player (chapter list) and in CarPlay
     (the Up Next chapter list, P5-04 #81). P2-07 (#54), whose scope lists "next and
     previous chapter", is amended to match this mapping.
   - `changePlaybackRate(supported:)` with the app's rate list.
   - Include `seekToPosition` **only** when the user allows seeking from media
     controls; leaving it out disables seeking.
4. **Lifecycle.**
   - On iOS, configure `AVAudioSession` (`.playback`, `.spokenAudio`) inside
     `#if os(iOS)` before `requestToBecomeApplicationPrimary()`.
   - Call `requestToBecomeSystemPrimary()` only on iOS and only from a
     user-initiated play while the app is in the foreground.
   - Set the session reference to `nil` when playback ends.
   - **CarPlay-only launch.** When the app is launched with only the CarPlay scene
     (for example, the phone is locked in a car), it isn't in the foreground.
     Apple's documentation for `requestToBecomeSystemPrimary()` says the app "must
     be in the foreground when calling this method, otherwise this request doesn't
     take effect". So on that path the call can't be made usefully. The same page
     says the call "isn't required [for local playback] unless your app needs to
     take over as the system primary from another session". P5-02 (#79) must handle
     this:
     - always call `requestToBecomeApplicationPrimary()` when playback starts from
       CarPlay;
     - treat `requestToBecomeSystemPrimary()` as best effort: skip it (or ignore its
       failure) when no foreground window scene is active, and never block playback
       on it;
     - rely on starting audio with an active `.playback` audio session to make us
       the system Now Playing app;
     - on device, check that CarPlay and the Lock Screen show our session after a
       CarPlay-only launch, including when another app was playing before.

     If they don't, that is a fallback trigger (see below).
5. **CarPlay** configures only `CPNowPlayingTemplate.shared`:
   - the Up Next button for chapters;
   - `allowsMiniPlayer`;
   - `CPNowPlayingPlaybackRateButton`, plus a `CPNowPlayingImageButton` for the sleep
     timer.

   It gets metadata and transport from the same `MediaSession`.
6. **App Intents** are `AudioPlaybackIntent`s that run in the app process and call
   the player. No extension publishes Now Playing, because `MediaSession` is
   unavailable in app extensions.

### Why not MediaPlayer

MediaPlayer is better documented for CarPlay and has richer chapter fields. But for
a 27-only, Swift 6, native-Mac app, NowPlaying gives us:

- one typed, Observation-driven code path on both OSes;
- async artwork with no `UIImage`/`NSImage` split;
- no `assumeIsolated` escape hatches;
- first-class App Intents bridging.

Those advantages apply to every surface. MediaPlayer's advantages are a narrower
layout gap (chapter plus book title) and a documentation gap (CarPlay), which we
handle with the runtime gate below.

### Fallback (all-or-nothing)

P2-07 (#54), P5-02 (#79) or P5-04 (#81) may find a blocking CarPlay or Lock Screen
failure on a device, for example: no metadata in CarPlay, broken transport, or a
scrubber that can't be hidden. In that case, write a **new ADR that supersedes this
one and switches every platform to MediaPlayer at once**. Invert the lint rule in
the same PR. Never fix a gap by adding MediaPlayer calls next to `MediaSession`.

### Lint rule

The rule lands with P2-07 (#54), not in this PR. Add this `mise` task and
make `lint` depend on it. It uses a TOML literal string, so the backslashes are not
escaped:

```toml
[tasks."lint:nowplaying"]
description = "ADR 0006: NowPlaying only, in ABSPlayback/NowPlaying; no MediaPlayer"
run = '''
#!/usr/bin/env bash
set -euo pipefail
# Native sources only; legacy ios/ still imports MediaPlayer and is not scanned.
dirs=()
for d in Audiobookshelf AudiobookshelfTests AudiobookshelfUITests AudiobookshelfWidgets Packages; do
  if [[ -d "$d" ]]; then dirs+=("$d"); fi
done
if ((${#dirs[@]} == 0)); then exit 0; fi
allowed='^Packages/AudiobookshelfKit/(Sources/ABSPlayback|Tests/ABSPlaybackTests)/NowPlaying/'
imp='^[[:space:]]*(@[_A-Za-z]+[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
mp_symbols='\bMP(NowPlaying|RemoteCommand|MediaItemArtwork|MediaItemProperty|AppEntityIdentifier|SkipInterval|ChangePlayback|ChangeRepeatMode|ChangeShuffleMode|FeedbackCommand|RatingCommand)[A-Za-z]*'
status=0
if grep -rnE --include='*.swift' \
    -e "${imp}(MediaPlayer|_MediaPlayer_AppIntents)([.[:space:]]|$)" -e "${mp_symbols}" "${dirs[@]}" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; then
  echo "error: MediaPlayer Now Playing APIs are banned; use the NowPlaying framework (ADR 0006)" >&2
  status=1
fi
if grep -rnE --include='*.swift' -e "${imp}(NowPlaying|_NowPlaying_AppIntents)([.[:space:]]|$)" "${dirs[@]}" \
    | grep -vE "${allowed}"; then
  echo "error: import NowPlaying only under ABSPlayback/NowPlaying/ or ABSPlaybackTests/NowPlaying/ (ADR 0006)" >&2
  status=1
fi
exit "$status"
'''
```

What the rule covers:

- **Paths.** It scans the native sources: the app (`Audiobookshelf`), its tests
  (`AudiobookshelfTests`, `AudiobookshelfUITests`), the widget, control and Live
  Activity extension (`AudiobookshelfWidgets`, added by P5-11a #88) and `Packages`.
  Folders that don't exist yet are skipped, so the task works before the extension
  lands. Legacy `ios/` is excluded on purpose, because it still imports MediaPlayer.
- **Allow-list.** `import NowPlaying` / `_NowPlaying_AppIntents` is allowed only
  under `Packages/AudiobookshelfKit/Sources/ABSPlayback/NowPlaying/` and its tests,
  `Packages/AudiobookshelfKit/Tests/ABSPlaybackTests/NowPlaying/`. Widgets can't use
  `MediaSession` anyway (it is unavailable in app extensions).
- **Import forms.** It catches attribute-prefixed imports
  (`@preconcurrency import MediaPlayer`), access-level imports, scoped imports
  (`import class MediaPlayer.…`) and submodule imports.
- **Re-exporting overlays.** It also bans `_MediaPlayer_AppIntents` and limits
  `_NowPlaying_AppIntents`, because each one `@_exported`-imports its base module.
- **No false positives on similar names.** `MediaPlayerX`, `NowPlayingKit` and a
  user type such as `MPPlayer` don't match.
- **Comments.** Lines that start with `//` are ignored, so comments may name
  MediaPlayer APIs.
- **Symbol check.** The MediaPlayer symbol grep is a backstop. The spike showed
  that `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` are *not* visible
  through `import CarPlay`, `AVKit`, `AVFoundation`, `SwiftUI` or
  `_NowPlaying_AppIntents`. `MediaPlaybackSnapshot` isn't visible through
  `CarPlay`, `AVKit`, `SwiftUI` or `_MediaPlayer_AppIntents`. So the import ban
  alone already prevents mixing within a file.

## Consequences

- Easier:
  - One `@Observable` model drives the app UI, the Lock Screen, the Mac and CarPlay.
  - No `nowPlayingInfo` dictionary or timer-driven refresh: update the model and the
    framework syncs.
  - Artwork comes from the same cover pipeline on both OSes (ADR 0005), via `Data`
    or `CGImage`.
- Harder or riskier:
  - CarPlay with NowPlaying is undocumented in the CarPlay docs; see the runtime
    gate under Validation.
  - The rate button may not reflect the current rate, because CarPlay documents
    observing `MPRemoteCommandCenter`. If so, use a `CPNowPlayingImageButton` that
    renders the rate. Don't add MediaPlayer.
  - The chapter-track layout loses the book title on system surfaces.
  - The framework is new, so expect 27.x behavior changes. Re-check the matrix when
    the minimum SDK moves.
  - Widgets and controls can't publish Now Playing. They must trigger app-process
    intents (`AudioPlaybackIntent`).
- Contributors must:
  - keep all NowPlaying code in `ABSPlayback/NowPlaying/`;
  - never import MediaPlayer;
  - change this decision only with a superseding ADR.
- Follow-ups:
  - P2-07 (#54) implements the session and the `lint:nowplaying` task. Its "next and
    previous chapter" scope is amended to remote next/previous = jump by the user's
    intervals (Decision rule 3). It also runs the Lock Screen, Control Center,
    AirPods, Mac media keys and intent checks below.
  - P5-02 (#79) and P5-04 (#81) run the CarPlay checks below. #79 also owns the
    CarPlay-only launch handling (Decision rule 4).
  - Each issue records its results in its PR.

## Validation

### Spike

The spike was throwaway code outside the repo and has been deleted. Build settings:

- Xcode 27.2 (27B52), Swift 6.4.2;
- `-swift-version 6 -strict-concurrency=complete`;
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The spike had four files:

- `Shared.swift`: a `BookEntity: AppEntity`, an `AudioPlaybackIntent` and a chapter
  struct.
- `OptionNowPlaying.swift`: an `@Observable @MainActor` `MediaSessionRepresentable`
  covering:
  - `BookContent` and `PodcastContent`;
  - chapter `(current, total)`;
  - chapter-relative duration and elapsed time;
  - `Data` and `CGImage` artwork;
  - all transport commands, with conditional `seekToPosition`;
  - `.playing(rate:)`;
  - `appEntityIdentifiers`;
  - `AVAudioSession` behind `#if os(iOS)`;
  - app-primary, plus iOS-only system-primary requests.
- `OptionMediaPlayer.swift`: the equivalent with a `nowPlayingInfo` dictionary,
  `MPMediaItemArtwork` (`UIImage`/`NSImage`), all remote commands,
  `changePlaybackPositionCommand.isEnabled`, `MPAppEntityIdentifier` and
  macOS `playbackState`.
- `CarPlaySpike.swift` (`#if os(iOS)`): configures `CPNowPlayingTemplate.shared`
  (Up Next, `allowsMiniPlayer`, `CPNowPlayingPlaybackRateButton`,
  `CPNowPlayingImageButton`, observer).

Typecheck results (`xcrun --sdk <sdk> swiftc -typecheck …`):

| Target | Shared + NowPlaying + CarPlay | Shared + MediaPlayer + CarPlay | Both options together |
| --- | --- | --- | --- |
| `arm64-apple-ios27.0-simulator` | exit 0 | exit 0 | exit 0 (mixing isn't a compile error) |
| `arm64-apple-ios27.0` (device SDK) | exit 0 | exit 0 | not run |
| `arm64-apple-macos27.0` | exit 0 | exit 0 | not run |

Other spike results:

- **App extensions.** `MediaSession(…)` compiled with `-application-extension`
  fails with "'MediaSession' is unavailable in application extensions for iOS".
- **Transitive visibility.** Single-file probes confirmed that neither API's
  symbols are visible without importing that API's module (results listed under
  Lint rule).
- **Lint dry run.** We ran the command above against a scratch tree with macOS BSD
  grep 2.6.0 and GNU bash 5.3, and the script passes `shellcheck`.
  - Empty tree, with none of the scanned folders present: exit 0.
  - Clean tree: exit 0. `AudiobookshelfTests` and `AudiobookshelfUITests` were
    missing, which shows that missing folders are skipped. NowPlaying imports
    appeared only in the allowed Sources and Tests `NowPlaying/` folders.
    `import MediaPlayerX`, `import NowPlayingKit`, a type named `MPPlayer` and an MP
    symbol inside a `//` comment were not flagged.
  - Seeded violations: exit 1, with every case flagged:
    - `@preconcurrency import MediaPlayer` and `MPRemoteCommandCenter` in
      `AudiobookshelfWidgets`;
    - `import NowPlaying` in `AudiobookshelfWidgets`;
    - `import _MediaPlayer_AppIntents` in `ABSUI`;
    - `import NowPlaying` in the app target;
    - `import NowPlaying` in `ABSPlaybackTests` outside `NowPlaying/`.
  - The first commit of this ADR used a fixed folder list. That version ran
    `grep -r` on missing folders, which exits 2, and under `pipefail` that could
    hide real violations. The folder filter fixes this.
- **Injected identifiers closure.** The `NowPlayingEntityIdentifiers` shape in
  Decision rule 2 typechecks (exit 0) for `arm64-apple-ios27.0-simulator` and
  `arm64-apple-macos27.0` with Swift 6 strict concurrency. The check used a stub
  `MediaKey` and a stub `BookEntity`/`EntityQuery`.

### Not verified (assumed from docs)

Nothing in this spike was run.

- No simulator or device run, so Lock Screen, Control Center, AirPods, Mac media key
  and CarPlay rendering are unverified for both options.
- Xcode 27.2 release notes (known issue 179494052) say Device Hub CarPlay needs a
  USB-connected device and doesn't support the iOS Simulator. The older Simulator
  "I/O → External Displays → CarPlay" route and the standalone CarPlay Simulator
  were not tried.
- Also unverified:
  - how `BookContent.chapter` is rendered;
  - whether leaving out `seekToPosition` hides the scrubber;
  - whether the CarPlay rate button reflects `changePlaybackRate`;
  - whether `next`/`previous` are what AirPods double and triple press send.

### Runtime gate

This ADR is Accepted on the strength of the typecheck spike. The on-device checks
are done by the issues that implement each surface, and each issue records its
results in its PR:

1. iPhone (physical device) Lock Screen and Control Center, performed in #54
   (P2-07):
   - title, author and artwork appear;
   - the chapter `n of N` display;
   - rate and elapsed-time extrapolation;
   - skip buttons show the configured intervals;
   - the scrubber is hidden when seeking is off.
2. AirPods, performed in #54 (P2-07):
   - play/pause;
   - double and triple press jump forward and back by the user's intervals;
   - pause when the route disconnects.
3. Mac media keys, the Control Center Now Playing item and artwork, performed in
   #54 (P2-07).
4. CarPlay, on a device via Device Hub, the CarPlay Simulator app, or a car:
   - performed in #79 (P5-02): metadata, transport, skip intervals, the mini
     player, and Now Playing after a CarPlay-only launch;
   - performed in #81 (P5-04): rate button behavior, the Up Next chapter list and
     the sleep-timer button.
5. A `PlayAudioIntent` / `AudioPlaybackIntent` from Shortcuts resumes the right
   item, and `appEntityIdentifiers` come from the injected closure. Performed in #54
   (P2-07).

If 1, 3 or 4 fail in a way that can't be fixed with NowPlaying APIs, apply the
fallback above.

### Ongoing

`mise run lint:nowplaying` runs in CI once #54 (P2-07) lands.

## References

- Research: [platform-apis.md §3.1 Now Playing](../research/platform-apis.md#31-now-playing-which-api-to-use),
  [§2.5 CPNowPlayingTemplate](../research/platform-apis.md#25-cpnowplayingtemplate-cpnowplayingtemplateh50118-cpnowplayingbuttonh13125),
  [§2.7 CarPlay testing](../research/platform-apis.md#27-testing),
  [§3.5 App Intents](../research/platform-apis.md#35-app-intents-siri-shortcuts).
- Apple documentation:
  - [Now Playing](https://developer.apple.com/documentation/nowplaying) (contains
    the "don't mix" note);
  - [Publishing media sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions);
  - [Playback commands](https://developer.apple.com/documentation/nowplaying/playback-commands);
  - [Content types and metadata](https://developer.apple.com/documentation/nowplaying/content-types-and-metadata);
  - [BookContent](https://developer.apple.com/documentation/nowplaying/bookcontent);
  - [MediaSession](https://developer.apple.com/documentation/nowplaying/mediasession);
  - [CPNowPlayingTemplate](https://developer.apple.com/documentation/carplay/cpnowplayingtemplate);
  - [CPNowPlayingPlaybackRateButton](https://developer.apple.com/documentation/carplay/cpnowplayingplaybackratebutton);
  - [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter);
  - [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter).
- Xcode 27.2 SDK (paths relative to each SDK's `System/Library/Frameworks/`):
  - `NowPlaying.framework/…/NowPlaying.swiftmodule/arm64e-apple-ios.swiftinterface`:
    - `MediaCommand` (lines 14–76; skip 67–68, seek 69, rate 72, `enabled` 15);
    - `MediaPlaybackSnapshot` (78–87);
    - `MediaSession` (107–139; iOS-only system primary 117–134; extension-unavailable
      108);
    - `MediaSessionRepresentable` (145–150);
    - `BookContent` (336–353; `chapter` 350);
    - `PodcastContent` (427–443);
    - `ArtworkRepresentation` and `Artwork` (481–499);
    - `MediaDuration` (529–533).
  - `NowPlaying.framework/Versions/A/…/arm64e-apple-macos.swiftinterface`: identical
    apart from build flags.
  - `_NowPlaying_AppIntents` (`MediaContentRepresentable.appEntityIdentifiers`) and
    `_MediaPlayer_AppIntents` (`MPAppEntityIdentifier`), iOS and macOS.
  - `MediaPlayer.framework/Headers`:
    - `MPNowPlayingInfoCenter.h` (`playbackState` :70, chapter keys :112/:115,
      `MPNowPlayingInfoPropertyAppEntityIdentifiers` :194);
    - `MPRemoteCommand.h` (`preferredIntervals` :70, `supportedPlaybackRates` :108,
      `MPChangePlaybackPositionCommand` :115);
    - `MPNowPlayingSession.h` (:19, unavailable on macOS);
    - `MPMediaItem.h` (artwork initializers :222/:231).
  - `CarPlay.framework/Headers/CPNowPlayingTemplate.h` (`sharedTemplate` :50,
    `allowsMiniPlayer` iOS 27.0 :90) and `CPNowPlayingButton.h`.
- Legacy:
  - [`ios/App/Shared/util/NowPlayingInfo.swift`](../../ios/App/Shared/util/NowPlayingInfo.swift);
  - [`ios/App/Shared/player/AudioPlayer.swift`](../../ios/App/Shared/player/AudioPlayer.swift)
    (lines 669–805).
- Related ADRs: [0001 Architecture](0001-architecture.md) (module rules, `ABSPlayback`
  owns Now Playing), [0005 Images](0005-images.md) (cover pipeline).
