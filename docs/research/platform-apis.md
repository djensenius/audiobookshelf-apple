# Research report: native SwiftUI Audiobookshelf client (iOS/iPadOS 27, iPhone Duo, macOS 27, CarPlay)


## 0. Executive summary and key decisions

1. **iPhone Duo.** SwiftUI has a new `ArrangementView` (split and overlay styles), `GeometryProxy.reservedRegions`, and vertical-bar toolbar APIs (`toolbarVerticalEdge`, `axisBehavior`, `visibilityPriority`, `ToolbarOverflowMenu`). Most of these are `anyAppleOS 27.1`.
   - The "Made for iPhone Duo" badge is earned by submitting Duo screenshots in App Store Connect.
   - From **April 2027**, apps built with the iOS 27.1+ SDK must include Duo screenshots.
2. **CarPlay audio.**
   - Setup needs a `CPTemplateApplicationSceneDelegate` and the `com.apple.developer.carplay-audio` entitlement, which Apple must grant.
   - Limits: 4 tabs, 5 Now Playing buttons, template depth of 5, and lists that some cars trim to 12 items.
   - **iOS Simulator is not supported for CarPlay in Xcode 27.2 Device Hub.** Device Hub needs a physical USB-connected device. The classic Simulator "External Displays → CarPlay" route and the Additional Tools CarPlay Simulator still exist.
3. **Now Playing (decision point).** iOS/macOS 27 add a new **NowPlaying framework** (`MediaSession`, `BookContent`, `PodcastContent`, `MediaCommand`).
   - **Apple says not to mix it with `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`** ("undefined behavior"). Pick one.
   - MediaPlayer still works on macOS and is the simpler path if you support earlier than 27.
4. **`AVURLAssetHTTPHeaderFieldsKey` is not public API.**
   - The old app uses the string literal for HLS transcode auth, and it works, but it is unsupported.
   - Audiobookshelf ≥ 2.22.0 direct play needs no token (`/public/session/{id}/track/{n}`), so avoid HLS transcode where possible.
5. **SwiftData on 27** has new `HistoryObserver`, `ResultsObserver`, `@Query(sectionBy:)` and `.codable` attributes. `@ModelActor`, `VersionedSchema` and history tracking are mature.
   - Use `.backgroundTask(.urlSession)` in place of `handleEventsForBackgroundURLSession`.
6. **OIDC.** Use `@Environment(\.webAuthenticationSession).authenticate(using:callback:preferredBrowserSession:additionalHeaderFields:)` with `.customScheme("audiobookshelf")`.
   - The Audiobookshelf server redirects through its own `/auth/openid/mobile-redirect` to `audiobookshelf://oauth`.
   - Use one cookie-carrying `URLSession` for the `/auth/openid` and `/auth/openid/callback` calls.
7. **String Catalogs.** Weblate does **not** support `.xcstrings` (WeblateOrg/weblate#10848, open). Keep Weblate on the JSON files and generate `Localizable.xcstrings` in a script or CI.
8. **Zip.** There is **no public Apple zip-extraction API**. Use **ZIPFoundation** (MIT, pure Swift, Compression-based).
9. **Socket.IO.** Audiobookshelf uses a websocket-only, default namespace, event-based auth: emit `42["auth","<JWT>"]`, then receive `42["init",{userId,username}]` or `42["auth_failed",{message}]`.

---

## 1. iPhone Duo in SwiftUI

### 1.1 Docs
- https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo.md
- https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo.md
- https://developer.apple.com/documentation/swiftui/arrangementview.md
- https://developer.apple.com/documentation/swiftui/splitarrangementviewstyle.md
- https://developer.apple.com/documentation/swiftui/overlayarrangementviewstyle.md
- https://developer.apple.com/documentation/swiftui/reservedregion.md
- https://developer.apple.com/documentation/swiftui/environmentvalues/toolbarverticaledge.md
- https://developer.apple.com/iphone-duo/ and https://developer.apple.com/iphone-duo/prepare/
- https://developer.apple.com/news/?id=kkphp5qo
- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- Tech Talks 111461–111466 (https://developer.apple.com/videos/play/tech-talks/NNNNNN/)

### 1.2 ArrangementView (SDK: `SwiftUICore.swiftinterface` ~4608–4660, 12831–12870, 16711–16780)
```swift
struct ArrangementView<Primary: View, Secondary: View>: View {
  init(@ContentBuilder primary: () -> Primary, @ContentBuilder secondary: () -> Secondary)
  init(_ configuration: ArrangementViewStyleConfiguration)   // for custom styles
}
extension View { func arrangementViewStyle(_ style: some ArrangementViewStyle) -> some View }
protocol ArrangementViewStyle { func makeBody(configuration: Configuration) -> some View }
// Configuration = ArrangementViewStyleConfiguration { primary, secondary }
```

**Styles** (all `anyAppleOS 27.1`; the `.split` / `.overlay` / `.automatic` members are static on `ArrangementViewStyle`):

| Style | Type | Notes |
|---|---|---|
| `.split` | `SplitArrangementViewStyle` | `.axes(_: Axis.Set)` limits the axes along which it splits |
| `.overlay` | `OverlayArrangementViewStyle` | `.axes(_:)` |
| `.automatic` | `AutomaticArrangementViewStyle` | |

**Split modifiers:**
- `splitArrangementLayoutRatio(_: CGFloat?)`
- `splitArrangementLayoutRatio(minHorizontal:idealHorizontal:maxHorizontal:minVertical:idealVertical:maxVertical:)`
- `splitArrangementLayoutSize(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:)`
- `splitArrangementFixedLayoutSize(horizontal:vertical:)`
- `EnvironmentValues.splitArrangementAxis: Axis?`

**Overlay modifiers:**
- `overlayArrangementEdge(_: VerticalEdge?)`
- `overlayArrangementEdge(_: HorizontalEdge?)`
- `EnvironmentValues.overlayArrangementZIndex: Int`

**Split behaviour:**
- It splits horizontally (primary leading) when the area is wider than tall, and vertically (primary top) when taller than wide.
- If an axis is not included, only the primary shows. The closed outer display in landscape shows only the primary.
- The default is 50/50, and the split shifts to align with the fold or reserved regions.

**Overlay behaviour:**
- On a flat display the primary floats above the secondary in z-order. Landscape gives a small floating primary along the bottom. Portrait places it near the centre.
- When folded in landscape, the secondary is leading and the primary is trailing.
- When folded in portrait, the secondary is on top and the primary at the bottom. Touch controls sit on the stable base.

**Rules from the docs:**
- Do not nest an `ArrangementView` in a `List`, `ScrollView`, `NavigationSplitView` or grid.
- Do not put a `NavigationSplitView` or `TabView` inside one. Put `NavigationStack` and `TabView` outside it.
- Use split for main/detail content (Apple's example is Now Playing as primary with transcript or Up Next as secondary). Use overlay for foreground/background content, such as controls over artwork.

### 1.3 Fold, reserved regions and hinge
- `struct ReservedRegion: Equatable, Hashable, Identifiable, Sendable` has `id`, `kind` (`.occlusion | .division`), `frame: CGRect`, `margins: EdgeInsets` and `isActive: Bool`.
- `ReservedRegion.QueryOptions: OptionSet` has `.includeInactive`.
- `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior: LayoutDirectionBehavior = .mirrors) -> [ReservedRegion]` (SwiftUICore ~4855–4950, 10338).
- UIKit equivalent: `UIView.reservedRegions(kind:options:)`.
- The fold is a `.division` region. It is active only when partially open and has zero width when flat. Compare `frame.height > frame.width` for direction:
  - a vertical fold is "book" pose with side-by-side panes;
  - a horizontal fold is "laptop" pose with stacked panes.
- The inner camera is an `.occlusion` region, active only while the camera is on. The outer camera is always present.
- Use `.includeInactive` for stable decisions, such as an even number of grid columns.
- Hinge: `View.onHingeChange(isEnabled:_ action: (DeviceHingeContext old, DeviceHingeContext new) -> Void)`.
  - `DeviceHingeContext.hinge: DeviceHinge?`.
  - `DeviceHinge { status: .closed | .partiallyOpen | .fullyOpen; angle: Angle }` (SwiftUICore ~16799, 24305).
  - UIKit has `UIHingeInteraction` and `UIHinge`.
  - Hinge data is meant for live effects, not layout.

### 1.4 Vertical bars and toolbars (`SwiftUI.swiftinterface`)

| API | Availability | Notes |
|---|---|---|
| `EnvironmentValues.toolbarVerticalEdge: HorizontalEdge?` | 27.1 | Read-only. UIKit: `UITraitCollection.verticalBarEdge` |
| `View.toolbarVerticalBehavior(.automatic \| .disabled)` | 27.1 | Opt out per toolbar |
| `ToolbarContent.axisBehavior(_: ToolbarItemAxisBehavior)` | 27.1, iOS | `.automatic`, `.horizontalOnly`, `.verticalPreferred` |
| `ToolbarContent.visibilityPriority(_: ToolbarItemVisibilityPriority)` | iOS 27.0 / macOS 26.1 | `.automatic`, `.low`, `.high`, `init(lowerThan:)`, `init(higherThan:)`. Default overflow order is bottom-to-top |
| `ToolbarItemPlacement.topBarPinnedTrailing` | iOS 27.0 | |
| `ToolbarOverflowMenu`, `View.toolbarOverflowMenu(content:)` | iOS 27.0, visionOS | **Unavailable on macOS.** Wrap in `#if os(iOS)` |
| `View.toolbarVerticalCompressionBehavior(.automatic \| .prefersToolbarItems \| .prefersTabBar)` | 27.1, iOS | |
| `View.backgroundExtensionEffect()` | iOS/macOS 26.0 | UIKit: `UIBackgroundExtensionView`. Extends content under the bar |
| `View.presentationPlacement(_:)` | anyAppleOS 27.0 | `.automatic` plus `.leading`, `.center`, `.trailing` (iOS only). UIKit: `UISheetPresentationController.preferredPlacement` |

**Behaviour:**
- Only bars from `NavigationStack`, `NavigationSplitView` and `TabView` are adapted. Custom UIKit bars are ignored.
- Vertical bars appear on the outer display and on the inner display in landscape. Inner portrait keeps horizontal bars.
- In a split view only the detail column goes vertical.
- Outer-display sheets are vertical. Inner-display sheets are centred and horizontal. A trailing placement gives a vertical bar.
- The vertical bar stays on the same physical side in RTL.
- Icon-only items go vertical. Title-only items and custom views stay horizontal unless `.verticalPreferred`.
- Always supply a `Label` with title and icon. Use `.badge` rather than inline counts.
- Flexible spacers collapse to zero on the vertical axis. Use `ToolbarItemGroup`.
- `TabView { … }.defaultTabBarPlacement(.sidebar)` gives a sidebar on the inner display.

### 1.5 Display and scene geometry
- Outer display: compact width. Portrait is regular height, landscape is compact height.
- Inner display: **regular width and regular height**. It does not honour supported interface orientations.
- Do not use `UIDevice.orientation`, idiom checks, or `UIScreen.main`. Use size classes and `onGeometryChange`.
- Use `@Environment(\.displayScale)` and `ConcentricRectangle`.
- Safe areas are asymmetric, so handle each edge separately. Use `.ignoresSafeArea()` for background art.
- Duo is the first multi-scene iPhone:
  - New windows cannot be created from the outer display.
  - Use `UIWindowSceneActivationAction`, which auto-hides when unavailable.
  - Scene accessories (`UISceneAccessory`, iOS 27.0) include `externalNonInteractive(sceneConfiguration:)` and, in 27.1, `cameraCapture(sceneConfiguration:)`. SwiftUI uses `.sceneAccessory { … }`.
  - Split View on Duo is 50/50, with a PiP-pinned-to-top layout.

### 1.6 Info.plist, resizability and Standby
- SDK-dependent behaviour:
  - **iOS 26 SDK or earlier:** the app runs in a centred window.
  - **iOS 27 SDK:** it fills the inner display but avoids the right status-bar edge.
  - **iOS 27.1 SDK or later:** full-screen, edge-to-edge on both displays, with vertical bars.
- Duo honours `UIRequiresFullScreen`, but the app still resizes when the device opens or closes, so avoid it. Support landscape, because tent pose is landscape.
- No Duo-specific Info.plist keys are documented.
- Apple ships an "App Resizability" skill with Xcode (`xcrun agent skills export`).
- **Standby:**
  - The Xcode 27.1 notes say Standby is unavailable in the Duo simulator runtime.
  - The 27.2 notes (Device Hub) add "Support for Standby in iPhone Duo".
  - URL: https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes.md
- **Xcode 27.2 / Device Hub caveats:**
  - Duo screenshots and recordings might be black for minutes after boot.
  - VoiceOver and the Accessibility Inspector are not usable on Duo.
  - Modifier keys can stop working when switching displays.
  - The `CameraCaptureAccessory` dual-display issue was fixed in 27.2.
  - Most app extensions can't run in the Duo simulator (27.1).
- Duo ships October 23, 2026.

### 1.7 "Made for iPhone Duo" badge
- Submit iPhone Duo screenshots in App Store Connect, and the product page shows "Made for iPhone Duo".
- Screenshot sizes: outer 1398×2034 or 2034×1398; inner 2007×2853 or 2853×2007.
- From **April 2027**, apps built with the iOS 27.1+ SDK must include Duo screenshots.
- A featuring nomination can claim "optimized for iPhone Duo, including all poses".
- Sources: the screenshot-specifications page above and news id kkphp5qo.

### 1.8 HIG guidance (key points)
- Do not tie functionality to a pose.
- Keep the same controls and hierarchy across poses and avoid dramatic motion.
- In laptop pose, put content to view at a distance on top and tappable controls on the bottom.
- Alerts, sheets, menus and popovers automatically avoid the fold.

### 1.9 Suggested adaptation (my synthesis, not Apple text)

| Pose | Audiobook player | Library browser |
|---|---|---|
| **Closed / outer** (compact width) | Single column: artwork, title, scrubber and transport. Chapters, speed and sleep in a `presentationPlacement(.trailing)` sheet. Transport and secondary actions go icon-only in the vertical bar (`.verticalPreferred` for play/pause). Use `backgroundExtensionEffect()` on the cover art. | `NavigationStack` with a 2-column cover grid, or list. Vertical bar holds search, sort and filter via `visibilityPriority` plus `ToolbarOverflowMenu` (iOS only). |
| **Open flat** (inner, regular × regular) | `ArrangementView` with `.split`: primary is player controls and artwork, secondary is chapters, up next, bookmarks or description. | `NavigationSplitView` (or `TabView` with `.defaultTabBarPlacement(.sidebar)`): sidebar for libraries, grid for content, detail for the book. Horizontal bars in portrait, vertical in landscape. |
| **Book fold** (vertical division) | Split places the player on one side and chapters/notes on the other. Keep both panes at an equal ratio (`splitArrangementLayoutRatio(0.5)`), and never put controls across the fold. | Grid columns stay even (query regions with `.includeInactive`) so no cover straddles the fold. Detail goes on the other side. |
| **Laptop / tabletop** (horizontal division) | Artwork, title and chapter on the top half. Scrubber, skip, play and speed on the bottom, stable half. `.overlay` also fits: artwork as secondary, controls as primary. | Cover grid or "continue listening" on top, the touch list or search on the bottom. |
| **Tent** (landscape) | Landscape layout, large artwork and transport. Treat it like normal landscape, with no special pose logic. | Normal landscape layout. |

Also:
- Branch on size classes, `ReservedRegion` and `toolbarVerticalEdge`, not on device orientation or a pose flag.
- Keep play/pause, skip and speed at `visibilityPriority(.high)`. Put rarely used items (sleep timer, bookmarks, download) in a `ToolbarOverflowMenu` on iOS and a plain `Menu` on macOS.
- The primary display for CarPlay and Duo scenes cannot be assumed to exist, so build the player model outside any view.

---

## 2. CarPlay audio apps

### 2.1 Docs and sources
- https://developer.apple.com/documentation/carplay.md
- …/carplay/displaying-content-in-carplay.md
- …/carplay/requesting-carplay-entitlements.md
- …/carplay/using-the-carplay-simulator.md
- …/carplay/integrating-carplay-with-your-music-app.md
- https://developer.apple.com/carplay/
- CarPlay Developer Guide PDF: https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf (dated 2026-10-13; see pp. 31–32 for scenes)
- WWDC26 session 212: https://developer.apple.com/videos/play/wwdc2026/212/
- Headers: `iPhoneOS27.2.sdk/System/Library/Frameworks/CarPlay.framework/Headers/`

### 2.2 Scene setup
- All CarPlay apps must adopt scenes. In Info.plist, `UIApplicationSceneManifest` → `UISceneConfigurations` carries the key `CPTemplateApplicationSceneSessionRoleApplication` (`CPTemplateApplicationScene.h:107`). The array entry contains:
  - `UISceneClassName` = `CPTemplateApplicationScene`
  - `UISceneConfigurationName`
  - `UISceneDelegateClassName` (your delegate class, which conforms to `CPTemplateApplicationSceneDelegate`)
- Apple's example also sets `UIApplicationSupportsMultipleScenes` = true. The guide's sample declares both a `UIWindowSceneSessionRoleApplication` scene and the CarPlay scene.
- Audio and non-navigation apps use `templateApplicationScene(_:didConnect interfaceController: CPInterfaceController)`, plus `didDisconnect`. Hold a strong reference to the interface controller. Navigation apps use the `CPWindow` variant instead.
- You must set a root template on connect.
- **The app can launch with only the CarPlay scene,** so the player, library and auth model must not depend on the phone UI being created.
- For a SwiftUI-lifecycle app (my inference from the guide):
  - Use `@UIApplicationDelegateAdaptor`.
  - Put the scene manifest in Info.plist, or return a `UISceneConfiguration` for the CarPlay role from `application(_:configurationForConnecting:options:)`.
  - Use a singleton shared player and model.

### 2.3 Entitlement
- Request at https://developer.apple.com/contact/carplay and agree to the CarPlay Entitlement Addendum. Apple reviews it against predefined criteria.
- Key: **`com.apple.developer.carplay-audio`** (iOS 14+). Related keys are `carplay-communication`, `carplay-charging`, `carplay-maps`, `carplay-parking` and `carplay-quick-ordering`.
- Once granted:
  - Enable "CarPlay Audio App (CarPlay framework)" on the App ID.
  - Create a provisioning profile.
  - Add an `Entitlements.plist` and set "Code Signing Entitlements".
  - Turn off automatic signing, or use the downloaded profile.
- The deprecated MediaPlayer-framework entitlement is `com.apple.developer.playable-content`.
- A CarPlay **video** entitlement is new in iOS 27. Content that suits both can include audio and video entitlements.
- Extra App Store Review rules:
  - Audio apps must never show lyrics on the CarPlay screen.
  - Audio apps that also provide video must support AirPlay video.
- Audio and video apps also appear on Apple HomeView with no changes.

### 2.4 Templates and limits

| Item | Limit or API |
|---|---|
| Templates allowed for audio apps | Action sheet (iOS 17+), Alert, Grid, List, Tab bar, Now Playing, Voice control (iOS 27+), Search (iOS 27+). An unsupported template throws |
| Template depth | **5 templates** pushed |
| On top of Now Playing | Only a `CPListTemplate` can be pushed |
| `CPTabBarTemplate.maximumTabCount` (class property) | Audio apps get up to **4 tabs**. More than 4 throws and may hide the now-playing button |
| `CPListTemplate.maximumItemCount` / `maximumSectionCount` (class properties) | Items beyond the limit are trimmed. The guide says some cars limit lists dynamically to **12 items**, so always handle it |
| `CPGridTemplateMaximumItems` (extern, iOS 15+) | Grid button limit |
| `CPListTemplate.maximumHeaderGridButtonCount` | iOS 26.0 |
| `CPListTemplate.maximumGridButtonImageSize` / `CPGridTemplate.maximumGridButtonImageSize` | iOS 26.0 |
| `CPListItem.maximumImageSize` | |
| `CPNowPlayingTemplate.nowPlayingButtons` | **Max 5**, filled leading to trailing. `updateNowPlayingButtons(_:)` |
| `CPNowPlayingButtonMaximumImageSize` | extern `CGSize` |
| `CPThumbnailImage.maximumImageSize(forAspectRatio:)` | iOS 27.0 |
| `CPListTemplateDetailsHeader.maximumActionButtonCount` / `maximumActionButtonSize` | iOS 26.4 |

(Header cites: `CPListTemplate.h:142–155, 247–265`; `CPTabBarTemplate.h:35–41`; `CPGridTemplate.h:14–40`; `CPInterfaceController.h:120–142`.)

**Image sizes (Developer Guide):**

| Image | Max (pt) | 3× px | 2× px |
|---|---|---|---|
| Contact action button | 50 | 150 | 100 |
| Grid icon | 40 | 120 | 80 |
| Now playing action button | 20 | 60 | 40 |
| Tab bar icon | 24 | 72 | 48 |
| Voice control image | 150 | 450 | 300 |

- Provide light and dark variants (`UIImageAsset`, `CPImageSet`). Use `CPInterfaceController.carTraitCollection` for scale.
- The now-playing image-button image should be a dark variant (the system recolours it). Animated images are not supported.

### 2.5 CPNowPlayingTemplate (`CPNowPlayingTemplate.h:50–118`, `CPNowPlayingButton.h:13–125`)
- `CPNowPlayingTemplate.shared` is a singleton. Configure it on `didConnect`.
- Properties:
  - `isUpNextButtonEnabled`, `upNextTitle`, `isAlbumArtistButtonEnabled`
  - `allowsMiniPlayer` (**iOS 27.0**, default YES)
  - `nowPlayingMode` (18.4)
- Observer methods: `nowPlayingTemplateUpNextButtonTapped(_:)`, `nowPlayingTemplateAlbumArtistButtonTapped(_:)`, `add/removeObserver`.
- Button classes (subclasses of `CPNowPlayingButton`, with `isEnabled` and `isSelected`):
  - `CPNowPlayingShuffleButton`
  - `CPNowPlayingAddToLibraryButton`
  - `CPNowPlayingMoreButton`
  - `CPNowPlayingPlaybackRateButton` (`init(handler:)`; the system cycles rates)
  - `CPNowPlayingRepeatButton`
  - `CPNowPlayingImageButton(image:handler:)` (custom, for example a sleep timer; **only this one supports a custom selected state**)
- Metadata comes from `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, or from the new NowPlaying framework. See topic 3 for the decision.
- Chapters and Up Next: `isUpNextButtonEnabled`, with a pushed `CPListTemplate` for the chapter list.

### 2.6 New CarPlay APIs, iOS 26–27
- **iOS 26.0:** `headerGridButtons` on lists, `CPListImageRowItem` elements, `CPGridButton.updateImage`, message grid items, map gestures.
- **iOS 26.4:**
  - `CPPlaybackConfiguration` and the `CPPlayableItem` protocol, which show progress on thumbnails (useful for resume progress on books).
  - `CPThumbnailImage`, `CPImageOverlay`, `CPSportsOverlay`.
  - `CPListTemplate.listHeader: CPListTemplateDetailsHeader`.
  - `CPSessionConfiguration.supportsVideoPlayback`.
  - Voice control action buttons.
- **iOS 27.0:**
  - `allowsMiniPlayer`, with an automatic MiniPlayer.
  - `CPInterfaceController.showOverlayTemplate(_:animated:completion:)` and `hideOverlayTemplateAnimated(_:completion:)` (overlay supports `CPVoiceControlTemplate` only).
  - Voice Control and Search templates.
  - Portrait or landscape thumbnails.
  - Video apps, map panels, EV charging.
- Audio-session guidance: deactivate the audio session when not playing, and test with the phone locked.

### 2.7 Testing
- **Simulator:** iOS Simulator → I/O → External Displays → CarPlay (800×480 @2x). `defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES` enables other sizes (for navigation apps).
  - It can't test Siri, locked-phone behaviour or real audio-session behaviour.
- **CarPlay Simulator app:** download via Additional Tools for Xcode (https://developer.apple.com/download/all/?q=additional%20tools%20for%20xcode). WWDC26 212 says the CarPlay Simulator is now also in Device Hub.
- **Xcode 27.2 release-notes known issue (179494052, FB23101450):** Device Hub support for CarPlay requires devices physically connected over USB (not the network). **iOS Simulator is not supported for CarPlay in Device Hub.**
- Apple recommends testing in a real car, or with wireless CarPlay and the debugger attached.

---

## 3. Audio playback across iOS and macOS

### 3.1 Now Playing: which API to use
**New NowPlaying framework** (iOS/macOS/tvOS/watchOS/visionOS 27.0; module "Now Playing"):
- Docs: https://developer.apple.com/documentation/nowplaying.md, …/publishing-media-sessions.md, …/playback-commands.md.
- **Apple's note: do not mix with `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` for local playback (undefined behavior).**
- `@MainActor class MediaSession<Representable: MediaSessionRepresentable>: Identifiable, Observable`:
  - `init(_ representable:)`
  - `isApplicationPrimary`, `canBecomeApplicationPrimary`
  - `requestToBecomeApplicationPrimary() async throws`
  - `requestToBecomeSystemPrimary() async throws` and `isSystemPrimary` (**iOS only**; the app must be foreground)
- `MediaSessionRepresentable` requires `id: String`, `content: (any MediaContentRepresentable)?`, `playbackSnapshot: MediaPlaybackSnapshot?` and `commands: [MediaCommand]`.
- `MediaPlaybackSnapshot(state:defaultPlaybackRate:elapsedTime:timestamp:)`. State is `.stopped | .playing(rate:) | .paused | .buffering | .interrupted`.
- `MediaCommand` factories:
  - `play`, `pause`, `stop`, `togglePlayPause`, `next`, `previous`
  - `skipForward(preferredIntervals:)`, `skipBackward`
  - `seekToPosition`, `seekForward`, `seekBackward`
  - `changePlaybackRate(supported:_:)`
  - `changeRepeatMode`, `changeShuffleMode`, `feedback`
- Content types:
  - `BookContent(id:title:authorName:narratorName:type:duration:artwork:)`, plus `chapter: (current:total:)?`, `genre`, `isExplicit`
  - `PodcastContent(id:episodeTitle:showName:releaseDate:type:duration:artwork:)`
  - Also `MusicContent`, `MovieContent`, `TVShowContent`, `RadioContent`, `HomeMediaContent`, `GenericContent`
- `Artwork(id:artworkProvider:)` with `ArtworkRepresentation(data:)` or `(cgImage:)`.
- `MediaDuration` is `.finite` or `.live`.
- On iOS, set up `AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)` and `setActive(true)` first.
- `RemoteMediaSession` and related types are **iOS only**.
- The `MediaIntents` framework (27.0) has `struct AudioSearch { criteria: .unspecified | .searchQuery(String) | .url([URL]) }`.
- Bridging modules: `_NowPlaying_AppIntents` (`appEntityIdentifiers`) and `_MediaPlayer_AppIntents` (`MPAppEntityIdentifier`).
- Interface: `NowPlaying.framework/.../arm64e-apple-ios.swiftinterface` (604 lines).

**MediaPlayer (legacy but supported):**
- `MPNowPlayingInfoCenter` (including `playbackState`, macOS 10.12.2+) and `MPRemoteCommandCenter` are `MP_API(macos(10.12.2))`, so they **work on macOS**. `changePlaybackPositionCommand` is available. The headers carry no deprecation.
- Recommendation: use MediaPlayer if you support anything below 27, or want one code path. Use NowPlaying for a 27-only app. Either way, pick one and keep CarPlay on the same choice.

### 3.2 AVAudioSession, macOS and interruptions
- **AVAudioSession is `API_UNAVAILABLE(macos)`** for the whole class (macOS SDK `AVAudioSession.h:31`). `setPrefersNoInterruptionsFromSystemAlerts` is also unavailable there.
- macOS alternatives:
  - `AVAudioApplication` (macOS 14+, iOS 17+): mic-mute state only.
  - `AVAudioRoutingArbiter` (macOS 11+, `AVAudioRoutingArbiter.h:48–61`): AirPods automatic-routing arbitration.
  - Output-device changes: CoreAudio `kAudioHardwarePropertyDefaultOutputDevice` via `AudioObjectAddPropertyListener`, `AVPlayer.audioOutputDeviceUniqueID`, `AVRoutePickerView` (AVKit).
  - There are no system interruptions on macOS, so gate session code with `#if os(iOS)`.
- iOS (from knowledge; not re-verified against headers this session):
  - `.playback` category. The old app uses mode `.spokenAudio` (`ios/App/Shared/player/AudioPlayer.swift`, `initAudioSession`).
  - Interruptions: `AVAudioSession.interruptionNotification` (`.began`/`.ended`, `.shouldResume`).
  - Route changes: `routeChangeNotification` with `.oldDeviceUnavailable` (headphones unplugged) should pause.
  - Background audio needs `UIBackgroundModes` = `audio` (iOS only).

### 3.3 AVPlayer / AVQueuePlayer
- `AVQueuePlayer` advances automatically (`actionAtItemEnd` is Advance). Other values are Pause and None (`AVPlayer.h:144–192`).
- Use `AVPlayer.defaultRate` (macOS 13 / iOS 16) for the user's chosen speed. `play()` uses `defaultRate`. AVPlayer can reset the rate on an interruption, so re-apply it.
- Pitch (`AVAudioProcessingSettings.h:14–50`), set on `AVPlayerItem.audioTimePitchAlgorithm`:
  - `.timeDomain`: voice-optimised, rate 1/32–32. It is the default for playback since iOS 15 / macOS 12, and the right choice for audiobooks and podcasts.
  - `.spectral`: music, most expensive.
  - `.varispeed`: no pitch correction.
  - `.lowQualityZeroLatency`: deprecated.
- For multi-file audiobooks, either build one `AVQueuePlayer` item per track (and track the offset), or an `AVMutableComposition`. The server's session already reports per-track `startOffset`.

### 3.4 HLS and auth headers
- **`AVURLAssetHTTPHeaderFieldsKey` is NOT a public symbol.**
  - Only the private `_AVURLAssetHTTPHeaderFieldsKey` appears in AVFoundation.tbd:1315.
  - The string literal `"AVURLAssetHTTPHeaderFieldsKey"` is undocumented and unsupported, but widely used.
  - Its behaviour on HLS segment and key requests varies, and I did not verify it.
- The old app uses it for the HLS transcode path: `AVURLAsset(url:…, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer <token>"]])` (`ios/App/Shared/player/AudioPlayer.swift:584-587`).
- Public `AVURLAsset` option keys (`AVAsset.h:548–620`):
  - `AVURLAssetPreferPreciseDurationAndTimingKey`
  - `AVURLAssetOverrideMIMETypeKey`
  - `AVURLAssetAllowsCellularAccessKey`
  - `AVURLAssetAllowsExpensiveNetworkAccessKey`
  - `AVURLAssetAllowsConstrainedNetworkAccessKey`
  - `AVURLAssetURLRequestAttributionKey`
  - `AVURLAssetHTTPUserAgentKey`
  - `AVURLAssetPrimarySessionIdentifierKey`
- Supported alternatives:
  - A `?token=` query parameter.
  - An `AVAssetResourceLoaderDelegate` with a custom scheme that re-issues requests with an Authorization header (more complex for HLS).
  - A local loopback proxy.
- **Audiobookshelf stream authentication** (verified in the old app and the server):

| Case | URL | Auth |
|---|---|---|
| Direct play, server ≥ 2.22.0 | `/public/session/{sessionId}/track/{index}` | **No token** (`SessionController` getTrack, PR #4263) |
| Direct play, older | `/api/items/{id}/file/{ino}?token=<token>` | Query token |
| HLS transcode | `track.contentUrl` (`/hls/{id}/output.m3u8`) | Bearer header via the private key (`AudioPlayer.swift:584-587`) |
| Covers | `/api/items/{id}/cover?token=` | Query token (`ios/App/Shared/util/NowPlayingInfo.swift:31`) |
| Downloads | `/api/items/{id}/file/{ino}/download?token=` | Query token (`ios/App/App/plugins/AbsDownloader.swift:454`; `DownloadItemPart.swift:81`) |

- The old app does a plain `AVURLAsset(url:)` for the direct-play session route (`AudioPlayer.swift:561-571`).
- HLS server details (`server/objects/Stream.js`): mpegts segments (fMP4 doesn't work on iOS), `-hls_time 6`, playlist at `/hls/{id}/output.m3u8`.
- **I did not verify whether the server accepts `?token=` on `/hls/` paths.**

### 3.5 App Intents, Siri, Shortcuts
- `public protocol AudioPlaybackIntent: SystemIntent` (macOS 14 / iOS 17 / watchOS 10 / tvOS 17; https://developer.apple.com/documentation/appintents/audioplaybackintent.md). It tells the system to avoid interrupting dialogs and runs the intent in the app process. Use it for play/pause, and for controls and widgets.
- `AppSchema.Intent.audio` (anyAppleOS 27.0; unavailable on watchOS and tvOS; `AppIntents.swiftinterface` ~323–396). Intents: `playAudio` (`PlayAudioIntent`), `addToLibrary`, `addToPlaylist`, `createStation`, `recognizeAudio`, `updateAudioAffinity`, `warmupAudioQueue`.
- `AppSchema.Entity.audio` includes `MediaBookEntity` (the audiobook entity, ~429), `PodcastShowEntity`, `PodcastEpisodeEntity`, `PodcastCollectionEntity`, `album`, `artist`, `playlist`, `song`, `WarmupAudioQueueResult` and others.
- `AppSchema.Enum.audio` (~514) includes `AudioAppViewIdentifier`, `AffinityState`, `AudioActivity`, `InvocationSource`, `PlaybackAttributes`, `QueueInsertionLocation`.
- The older `.books` `playAudiobook`/`audiobook` schemas are deprecated in 27.0 in favour of `.audio`.
- **I did not read the `PlayAudioIntent` parameters.**

### 3.6 WidgetKit controls and Live Activities
- **Control Center controls** (`ControlWidget`, `StaticControlConfiguration`, `AppIntentControlConfiguration`, `ControlWidgetButton`, `ControlWidgetToggle`): iOS 18.0, **macOS 26.0**, watchOS 26.0. Unavailable on tvOS and visionOS.
  - Cites: macOS WidgetKit swiftinterface ~500–505, 1093–1097; iOS ~504, 1137, 1192, 1287.
- **ActivityKit Live Activities** (`Activity<Attributes>`): iOS 16.1 only. **macOS and Catalyst are unavailable** (macOS ActivityKit swiftinterface lines 36–48). On macOS use Now Playing, widgets and controls.

---

## 4. SwiftData and background URLSession

### 4.1 SwiftData maturity on 27 (swiftinterface 1483 lines)
Core APIs (iOS 17 / macOS 14+):
- `ModelConfiguration` (`name`, `schema`, `isStoredInMemoryOnly`, `allowsSave`, `groupContainer`, `cloudKitDatabase`, `url`).
- `ModelContainer(for:migrationPlan:configurations:)`, `@MainActor mainContext`, `erase()` (iOS 18+; `deleteAllData` is deprecated).
- `ModelContext`: `fetch`, `fetchCount`, `fetchIdentifiers`, `insert`, `delete(model:where:)`, `transaction`, `save`, `enumerate(_:batchSize:allowEscapingMutations:block:)`, `author`, `autosaveEnabled`.
- `protocol ModelActor` has `nonisolated var modelContainer`, `nonisolated var modelExecutor: any ModelExecutor`, `modelContext` and `subscript(id:as:)`.
  - The `@ModelActor` macro generates `modelExecutor`, `modelContainer` and `init(modelContainer:)`.
  - `DefaultSerialModelExecutor(modelContext:)` (lines ~119–165).
- Macros: `@Model`, `@Attribute(...)` (`.unique`, `.preserveValueOnDeletion`, `.externalStorage`, and **new `.codable` in 27**), `@Relationship`, `@Transient`, `#Unique<T>(...)`, `#Index<T>(...)` (binary or R-tree), `@Query`.

**Migrations** (~855–870):
- `protocol VersionedSchema { static var models; static var versionIdentifier: Schema.Version }`
- `protocol SchemaMigrationPlan { static var schemas; static var stages: [MigrationStage] }`
- `MigrationStage.lightweight(fromVersion:toVersion:)`
- `MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
- Errors: `SwiftDataError.backwardMigration`, `.unknownSchema`, `.unknownDataStoreSchema` (27).

**History tracking** (iOS 18 / macOS 15, ~663–850):
- `HistoryDescriptor<T>` (`predicate`, `fetchLimit`, `sortBy` from 26).
- `ModelContext.fetchHistory` and `deleteHistory`.
- `DefaultHistoryTransaction`, `DefaultHistoryToken` (Codable, Comparable), `HistoryProviding`.
- `DefaultHistoryInsert`/`Update`/`Delete`, `HistoryTombstone`, and `.preserveValueOnDeletion`.
- `SwiftDataError.historyTokenExpired` (27).
- Docs: https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes.md.

**New in iOS/macOS 27** (confirmed on https://developer.apple.com/documentation/updates/swiftdata.md, June 2026):
- `HistoryObserver` (`init(historyTokens:observedModels:authors:modelContainer:isolation:)`, `eventCounter`; observes `ModelContainer.remoteChange`; `@Observable`; ~960–975).
- `ResultsObserver<Element, SectionTitle>`: observable fetch results with `sectionBy`, `sections`, `element(at:)`, `indexPath(for:)`. It reacts to local, remote-context and external-process changes (~255–320).
- `SectionedResults`, `ResultsSection`, and `@Query` with `sectionBy` / `Query.sections`.
- `ModelContainer.storeIdentifier(forConfigurationNamed:)` and `configurationName(forStoreIdentifier:)`, `PersistentModel.isTemporary`.
- The Xcode 27 / 27.1 / 27.2 release notes contain **no SwiftData-specific entries**.

**Recommended offline-cache and downloads pattern (my synthesis):**
- Write in the background through a `@ModelActor`. Pass `PersistentIdentifier` or Sendable DTOs between actors, never `@Model` objects.
- Store file locations **relative to the container**. The absolute path changes between app updates.
- Key rows by server item id (`@Attribute(.unique)` or `#Unique`), add `#Index` for filtered fields, and store `resumeData` with `.externalStorage`.
- Keep a download record per file or part (state, bytes, task id, `resumeData`), updated from the URLSession delegate through the model actor.
- Drive the UI with `@Query`, `ResultsObserver` or `HistoryObserver`.
- Version the schema from day one (`VersionedSchema` plus a `SchemaMigrationPlan`).
- Keep the high-frequency playback-progress path outside SwiftData, or batch it, to avoid write amplification. Sync it to the server separately.

### 4.2 Background URLSession on iOS and macOS
- SwiftUI replacement for `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (`BackgroundTask`, iOS 16 / macOS 13+):
  ```swift
  static var urlSession: BackgroundTask<String, Void>
  static func urlSession(_ identifier: String) -> BackgroundTask<Void, Void>
  static func urlSession(matching: @escaping @Sendable (String) -> Bool) -> BackgroundTask<String, Void>
  // used as: Scene.backgroundTask(_:action:)
  ```
  - Cites: iOS SwiftUI swiftinterface 23648–23663; macOS 24270–24285.
  - Docs: https://developer.apple.com/documentation/swiftui/backgroundtask/urlsession(_:).md.
- The system calls the action when the app is relaunched or resumed for session events. Recreate a `URLSession` with the **same background identifier** inside the action so delegate events are delivered, then finish through `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
- Article: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background.md.
  - `URLSessionConfiguration.background(withIdentifier:)`.
  - `sessionSendsLaunchEvents` (macOS 11+, default true), `isDiscretionary`, `sharedContainerIdentifier`.
  - `earliestBeginDate`, `countOfBytesClientExpectsToSend`/`Receive`.
  - Move the file **synchronously** inside `didFinishDownloadingTo`.
  - `cancelByProducingResumeData` and `downloadTask(withResumeData:)`.
- On macOS the background-session API exists (macOS 10.10+), the process is not suspended like on iOS, and transfers run via `nsurlsessiond`. There is no `UIApplicationDelegate` hook on macOS, so `.backgroundTask(.urlSession)` is the portable route.
- Cites (macOS Foundation `NSURLSession.h`): `sessionSendsLaunchEvents` line 1421, `backgroundSessionConfigurationWithIdentifier` line 1297.
- Large audiobook downloads: use a background session with `isDiscretionary = false`, and one task per file part.

---

## 5. ASWebAuthenticationSession for OIDC with PKCE

### 5.1 SwiftUI API
- `@MainActor struct WebAuthenticationSession` (module `_AuthenticationServices_SwiftUI`; iOS 16.4 / macOS 13.3 / watchOS 9.4 / tvOS 16.4 / visionOS 1.0). Get it via `@Environment(\.webAuthenticationSession)`.
- `BrowserSession.ephemeral` and `.shared`.
- **Preferred** (iOS 17.4 / macOS 14.4 / visionOS 1.1):
  ```swift
  func authenticate(using url: URL,
                    callback: ASWebAuthenticationSession.Callback,
                    preferredBrowserSession: BrowserSession? = nil,
                    additionalHeaderFields: [String: String]) async throws -> URL
  ```
  `additionalHeaderFields` has **no default value**, so pass `[:]`.
- Deprecated: `authenticate(using:callbackURLScheme:preferredBrowserSession:)`.
- Cites: `_AuthenticationServices_SwiftUI` swiftinterface lines 141–163 (iOS and macOS are identical). Docs: https://developer.apple.com/documentation/authenticationservices/webauthenticationsession.md.
- `ASWebAuthenticationSession.Callback` (`ASWebAuthenticationSessionCallback.h:10–25`, iOS 17.4 / macOS 14.4):
  - `.customScheme(_ customScheme: String)`
  - `.https(host:path:)` (the host must be associated through associated-domains web credentials)
- Header notes (`ASWebAuthenticationSession.h:36–92`):
  - A custom-scheme callback needs no Info.plist registration when the scheme is passed to the session.
  - `additionalHeaderFields` names must start with `X-`.
  - Cancel raises `ASWebAuthenticationSessionErrorCodeCanceledLogin`.
  - A shared Safari session prompts the user for consent. `.ephemeral` avoids it.
- macOS needs the `com.apple.security.network.client` sandbox entitlement.

### 5.2 Audiobookshelf OIDC flow (verified in the old app and the server)
Old app: `components/connection/ServerConnectForm.vue` ~196–440. Server: `server/Auth.js`, `server/auth/OidcAuthStrategy.js`.

1. Generate a PKCE verifier (random hex) and a challenge (S256, base64url) (~265–290).
2. `GET {server}/auth/openid?code_challenge=…&code_challenge_method=S256&redirect_uri=audiobookshelf%3A%2F%2Foauth&client_id=Audiobookshelf-App&response_type=code` with redirects disabled (`redirect: manual`). Read the `Location` header, which is the IdP authorize URL (292–315).
3. Rebuild the URL with `client_id`, `scope`, `state`, `redirect_uri` (the server's `…/auth/openid/mobile-redirect`) and the PKCE challenge, then open it in the browser session (226–256).
4. The IdP redirects to the server's `/auth/openid/mobile-redirect?code&state`. The server looks up the state and redirects to **`audiobookshelf://oauth?code=…&state=…`** (`OidcAuthStrategy.js:484-509`; route in `Auth.js` ~370-383).
5. The app verifies `state`, then calls `GET {server}/auth/openid/callback?state=…&code=…&code_verifier=…` (384–386).
6. The response matches `/login`. Server ≥ 2.26.0 returns `user.accessToken` and `refreshToken`; older servers return `user.token` (384–420).

Notes:
- 2.6.0 compatibility quirks (`isRest=true`, forced redirect_uri) are not needed for new work.
- Require HTTPS.
- **Cookie caveat (inferred from express-session and `getAuthorizationUrl`):** the server keeps PKCE and state in `req.session`, so the `/auth/openid` request and the `/auth/openid/callback` request must share one `URLSession` with a cookie jar. Do not use per-request ephemeral sessions.
- Use a redirect-suppressing delegate (`willPerformHTTPRedirection` → `nil`) to capture `Location`.
- For the new app: `callback: .customScheme("audiobookshelf")`. A different scheme would require the server's redirect allow-list to accept it, which is **unverified**.
- For mobile token handling:
  - `/login` supports an `x-return-tokens: true` header.
  - `/auth/refresh` accepts an `x-refresh-token` header (`server/Auth.js` ~321-335).
  - Store refresh tokens in the Keychain.

---

## 6. String Catalogs

- The repo's `strings/` folder has 42 flat JSON files (`ar, be, bg, bn, ca, cs, da, de, el, en-us, es, et, fa, fi, fr, gu, he, hi, hr, hu, is, it, ja, ko, lt, lv, nl, no, pl, pt-br, ro, ru, sk, sl, sv, ta, tr, uk, uz, vi-vn, zh_Hant, zh-cn`).
  - `en-us.json` has **381 keys** in a flat `"ButtonAdd": "Add"` shape.
  - 19 strings use positional `{0}`/`{1}` placeholders, some contain HTML (`<strong>{0}</strong>`), and none have plural forms.
- Locale mapping needed: `en-us→en`, `pt-br→pt-BR`, `zh-cn→zh-Hans`, `zh_Hant→zh-Hant`, `vi-vn→vi`, `no→nb`.
- Placeholders: convert `{0}` to `%1$@` or `%1$lld` (positional), or use Xcode 26+ expressive specifiers (`%(name)@`).
- `.xcstrings` shape (from knowledge and Tolgee docs; **not validated locally**):
  ```json
  {"sourceLanguage":"en","version":"1.0","strings":{"ButtonAdd":{"comment":"…","extractionState":"manual","localizations":{"de":{"stringUnit":{"state":"translated","value":"Hinzufügen"}}}}}}
  ```
  Plurals go in `variations.plural.{one|other|…}.stringUnit`.
- Apple publishes no format specification, and Xcode "reserves the right to change" it (Apple forums thread 732120, quoted in translate/translate#5190).
- Xcode support:
  - **Xcode 26+:** the build setting "Generate String Catalog Symbols" creates type-safe symbols for manually managed strings (`extractionState: manual`).
  - Xcode 26+ also adds expressive format specifiers and a Refactor menu for converting between auto-extracted and manual strings.
  - Xcode 27 adds agent-based translation and MCP tools for string catalogs.
  - Doc: https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog.md.
- `xcstringstool` ships at `/Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool` (`print`, `compile`, `sync`, `extract`, `generate-symbols`, `installloc`). Use it to validate a converted catalog; I did not run it because that would need a written file.
- **Weblate does not natively support `.xcstrings`.**
  - WeblateOrg/weblate#10848 "Support String Catalog (.xcstrings)": open since 2024-01-24, labels "Waiting for: Demand", "Blocked by upstream".
  - It is blocked by translate-toolkit (translate/translate#5190, open, no xcstrings storage module) and by the multi-language-file limitation (WeblateOrg/weblate#11039, open).
  - Weblate 2026.11.2 supports Apple `.strings`, `.stringsdict` and XLIFF (`apple-xliff`). Docs: https://docs.weblate.org/en/latest/formats/apple.html. There is no xcstrings page.
- **Recommended workflow:** keep Weblate on the existing flat JSON files, and generate `Localizable.xcstrings` from them in CI or a script. Add `extractionState: manual` and a `comment`. Alternatively, round-trip through `.xcloc` / XLIFF from Xcode. Tolgee (https://docs.tolgee.io/platform/formats/apple_xcstrings) and SimpleLocalize do support xcstrings if you change platforms.

---

## 7. Zip / CBZ extraction

- **No public Apple API extracts `.zip`/`.cbz` on iOS 27.2 / macOS 27.2.** I grepped the SDKs:
  - **Foundation:** only `NSItemProvider` docs mention zip (a folder provided as `NSData` is a zip), and `NSFileCoordinator` `.forUploading` can produce a zip. Neither extracts.
  - **Compression** (`compression.h`): raw algorithms only (`COMPRESSION_ZLIB` is raw DEFLATE RFC 1951, plus LZ4, LZ4_RAW, LZMA, BROTLI, LZFSE, LZBITMAP). No container format. See https://developer.apple.com/documentation/compression.md.
  - **AppleArchive** (macOS 11 / iOS 14): its own `.aar`/`.yaa` format. `ArchiveCompression` has none, lz4, zlib, lzma, lzfse, lzbitmap, lzraven. **No ZIP.**
  - `zlib.h` offers inflate/gzip only (no minizip). `libarchive.tbd` is in the SDK `usr/lib` but there is no `archive.h`, so it is not public API.
  - **macOS-only fallback:** `Process` with `/usr/bin/ditto -x -k` or `/usr/bin/unzip` (not on iOS; sandbox behaviour unverified).
- DIY alternative: parse the central directory and inflate method-8 entries with Compression `COMPRESSION_ZLIB`. This needs ZIP64 handling and ZIP-slip checks.

**SPM candidates (GitHub API):**

| Package | Stars | Last push | Latest release | License | Open issues | Notes |
|---|---|---|---|---|---|---|
| **weichsel/ZIPFoundation** | 2753 | 2026-09-12 | 0.9.20 (2025-09-24) | MIT | 45 | Pure Swift, Compression-based, active |
| ZipArchive/ZipArchive (SSZipArchive) | 5604 | 2025-10-31 | 2.6.0 (2024-10-03) | MIT | 69 | Objective-C, minizip |
| marmelroy/Zip | 2603 | 2024-08-05 | 2.1.2 (2022-02-23) | MIT | 120 | Stale |
| nmoinvaz/minizip-ng | 1511 | 2026-11-06 | 4.2.2 (2026-06-30) | NOASSERTION | 11 | C library, heavier |
| tsolomko/SWCompression | 278 | 2026-07-01 | 4.9.1 (2026-06-13) | MIT | 10 | Pure Swift, many formats |

**Recommendation: ZIPFoundation** (https://github.com/weichsel/ZIPFoundation).
- README features: modern Swift API, large-file (ZIP64) support, in-memory archives, deterministic memory use, and no third-party dependencies on Apple platforms (zlib only on Linux). It lists iOS 12+, macOS 10.11+, visionOS 1+.
- API: `FileManager.default.unzipItem(at:to:)`, `Archive(url:accessMode:)`, `archive[entryPath]`, and `archive.extract(entry, to:)` or the closure-based `extract(_:consumer:)`. Reading single entries lets you pull one cbz page without unpacking everything.
- **Xcode 27 caveats** (open issues, not fixed in the 0.9.20 tag):
  - #401: the `.xcodeproj` deployment targets (iOS 12) are below Xcode 27's minimum (iOS 15) and hard-fail. This only affects people opening the project or Carthage users.
  - #402: SPM silently ignores below-minimum platform values and builds for the supported minimum. Harmless to SPM consumers.
  - #407 and #403 (open PRs) raise the minimums and add a `Package@swift-6.4.swift` (Swift 5 language mode).
  - #345 "Swift 6 Support" has been open since 2024-12, so expect Sendable warnings if you share `Archive` across actors.
  - I did not build it. Pin to the 0.9.20 tag (or a revision) and confirm that it builds in your project.

---

## 8. Socket.IO v4 / Engine.IO v4 minimal client over `URLSessionWebSocketTask`

### 8.1 Spec links
- https://github.com/socketio/engine.io-protocol (README.md)
- https://github.com/socketio/socket.io-protocol (**Readme.md**; `README.md` returns 404)
- Rendered versions at https://socket.io/docs/v4/engine-io-protocol/ and https://socket.io/docs/v4/socket-io-protocol/ (not fetched)
- Client options: https://socket.io/docs/v4/client-options/
- Reference client reconnect logic: https://github.com/socketio/socket.io/blob/main/packages/socket.io-client/lib/manager.ts (lines 172–181) and `lib/contrib/backo2.ts`

### 8.2 Engine.IO v4 (verified in the README)
- **URL (websocket-only):** `GET /socket.io/?EIO=4&transport=websocket`. `EIO=4` and `transport` are mandatory. The server closes the socket if one is missing. `sid` is optional, only for upgrades from polling.
  - Use `ws://` or `wss://` for `URLSession.webSocketTask`.
  - Socket.IO's default path is `/socket.io/`, and the client adds a trailing slash (`addTrailingSlash` default true). The Audiobookshelf server also serves `<RouterBasePath>/socket.io`.
- **Framing:** each packet is its own WebSocket frame. Format `<type>[data]`. Text frames carry text packets, binary frames are sent as-is, and there is no `\x1e` separator on WebSocket (that is polling only).
- **Packet types:**

| Type | ID | Use |
|---|---|---|
| open | 0 | Handshake (server → client) |
| close | 1 | Transport may be closed |
| ping | 2 | Heartbeat. In v4 sent by the **server** |
| pong | 3 | Heartbeat reply (client → server) |
| message | 4 | Carries a Socket.IO packet |
| upgrade | 5 | Polling→WebSocket upgrade only |
| noop | 6 | Upgrade only |

- **Handshake:** the server immediately sends an open packet such as `0{"sid":"…","upgrades":[…],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}` (the values shown are the engine.io defaults, not read from a live Audiobookshelf server; always use the values from the handshake, never hard-code them). The sid goes on all later requests (needed for polling only). `maxPayload` governs polling aggregation, so it is not needed for WebSocket-only.
- **Heartbeat:**
  - Every `pingInterval`, the server sends `2`. The client replies **`3`** within `pingTimeout`.
  - If the client sees no ping within `pingInterval + pingTimeout`, it must treat the connection as dead and reconnect.
  - Reset a timer on every received `2`.
  - Do **not** use `URLSessionWebSocketTask.sendPing`, which is a WebSocket-level ping unrelated to Engine.IO.
- Upgrade (`2probe`/`3probe`/`5`) is irrelevant for a WebSocket-only client.
- Audiobookshelf passes no Socket.IO server options besides CORS (`SocketAuthority.js:155-180`), so the defaults apply (typically 25000/20000/1e6, from the engine.io README example; not read from server code).

### 8.3 Socket.IO v4 packets (verified in Readme.md)
- **Packet types:** 0 CONNECT, 1 DISCONNECT, 2 EVENT, 3 ACK, 4 CONNECT_ERROR, 5 BINARY_EVENT, 6 BINARY_ACK.
- **Encoding:** `<type>[<#binary>-][<namespace>,][<ackId>][JSON payload]`. The namespace is only included when it isn't `/`. On the wire everything is wrapped as an Engine.IO message, so prefix `4`.

| Intent | Wire text |
|---|---|
| Connect to main namespace (client) | `40` |
| Connect with auth payload | `40{"token":"123"}` |
| Connect to `/admin` | `40/admin,` |
| Server accepts | `40{"sid":"wZX3oN0bSVIhsaknAAAI"}` |
| Server rejects | `44{"message":"Not authorized"}` |
| Event | `42["event",arg1,…]` (payload is a non-empty array, event name first) |
| Event with ack id 12 | `4212["foo"]` (namespaced: `42/admin,12["foo"]`) |
| Ack | `4312[…]` (payload is an array, possibly empty) |
| Disconnect namespace | `41` |
| Binary event (placeholder) | `451-["baz",{"_placeholder":true,"num":0}]`, followed by a binary frame |

- The first Socket.IO packet must be CONNECT, otherwise the server closes. A client can connect to several namespaces on one WebSocket.
- After `41`, close the socket normally: `task.cancel(with: .normalClosure, reason: nil)`.
- Binary events (5/6): Audiobookshelf's observed events are JSON-only, so a minimal client can ignore binary types and `.data` messages. I did not audit every server emit.

### 8.4 Reconnection (reference client, verified in `manager.ts:172-181` and `backo2.ts`)
- Defaults: `reconnectionAttempts` ∞, `reconnectionDelay` 1000 ms, `reconnectionDelayMax` 5000 ms, `randomizationFactor` 0.5, `timeout` 20000 ms.
- Backoff: `ms = min * 2^attempts`, then add or subtract a random deviation of up to `jitter * ms`, then clamp to `max`. Reset the attempts counter after a successful connect.
- The old Audiobookshelf client raises the max to 15000 ms (`plugins/server.js:34-40`).
- On every reconnect you get a new Engine.IO sid and a new Socket.IO sid. **Re-send `auth` after every `40{…}` ack** (the old app does it in `onConnect`, `plugins/server.js:63-66`).
- Also reconnect on app foreground and on `NWPathMonitor` changes. On iOS, background suspension kills the socket.

### 8.5 `URLSessionWebSocketTask` API notes (`NSURLSession.h`, iOS 27.2 SDK)
- `webSocketTask(with: URL)` (line 499), `…(with: URL, protocols:)` (511), `…(with: URLRequest)` (523). Available iOS 13 / macOS 10.15. Use the `URLRequest` form to add headers (for example for a reverse-proxy auth header).
- `send(_:)` and `receive()` async wrappers exist in Foundation Swift (`send(_ message:) async throws`, `receive() async throws -> URLSessionWebSocketTask.Message`). Messages are `.string(String)` or `.data(Data)`.
- Delegate callbacks: `urlSession(_:webSocketTask:didOpenWithProtocol:)` (1931), `…didCloseWith:reason:` (1937).
- `maximumMessageSize` (1169) is the buffer cap. If it is reached, `receive` errors and the task ends (1138–1141). Raise it for large library payloads (`item_added` carries expanded JSON; an admin `init` carries `usersOnline`).
- `cancel(with: closeCode, reason:)` (`cancelWithCloseCode:reason:`, 1163).
- Needs a reverse proxy that forwards WebSocket upgrades. On macOS the sandbox needs `com.apple.security.network.client`.

**Minimal receive loop (sketch):**
```swift
for try await msg in stream {                 // wrap task.receive() in a loop
  guard case .string(let s) = msg, let t = s.first else { continue }
  switch t {
  case "0": handshake = try JSON(s.dropFirst()); send("40")        // 40 or 40{"token":…}
  case "2": resetPingTimer(handshake.pingInterval + handshake.pingTimeout); send("3")
  case "4": handleSocketIO(String(s.dropFirst()))                  // "0{sid}" connected, "2[…]" event, "44{…}" error
  case "1": reconnect()
  default: break
  }
}
```

### 8.6 Audiobookshelf-specific behaviour (verified)

**Server** (`advplyr/audiobookshelf:server/SocketAuthority.js`, indexed commit 83dce68):
- Options: `{ cors: { origin: '*', methods: ['GET','POST'] } }`, path `/socket.io`, and also `${RouterBasePath}/socket.io` when a router base path is set (lines 155-180).
- On `connection`: it registers handlers for `auth` (`(token) => authenticateSocket(socket, token)`), `cancel_scan` (admin), `search_covers`, `cancel_cover_search`, `set_log_listener` (admin), `message_all_users` (admin) and `ping` (replies with an app-level `pong` event, unrelated to Engine.IO ping) (lines 181-256).
- `authenticateSocket(socket, token)` (270-361):
  - Validates the JWT (`TokenManager.validateAccessToken`). For API-key tokens it checks the key is active.
  - Failures emit `auth_failed` with `{message}`: `'Invalid token'`, `'Token expired'`, `'Invalid API key'`, `'Invalid user'`.
  - Success sets `client.user`, notifies admins with `user_online`, and emits **`init`** with `{userId, username}` (admins also get `usersOnline`). Re-authenticating a socket for the same user is allowed.
- **Events only reach authenticated sockets.** `emitter` skips clients without a user, and `clientEmitter(userId, …)` targets all of a user's sockets (`SocketAuthority.js` ~56–82 in current master).
- Access tokens are short-lived on server ≥ 2.26, so after `auth_failed` ("Token expired") refresh via `/auth/refresh` and emit `auth` again.

**Old app client** (`plugins/server.js:34-110`):
- `io(serverHost, { transports: ['websocket'], upgrade: false, path: `${serverPath}/socket.io`, reconnectionDelayMax: 15000 })`. `serverPath` is the URL path prefix, if the server is hosted under a subpath.
- Listens for `connect`, `disconnect`, `init`, `auth_failed`, `user_updated`, `user_item_progress_updated`, `playlist_added`, and the Manager's `reconnect_attempt`, `reconnect_error` and `reconnect_failed`.
- On `connect` it emits `auth` with the stored token.
- `user_item_progress_updated` payload (server `PlaybackSessionManager.js` ~265 and ~402): `{ id, sessionId, deviceDescription, data: <oldMediaProgress> }`. The client stores `payload.data` as the user's media progress. This is the key event for cross-device progress sync.
- Web-client events that the server also emits to authed clients (`client/layouts/default.vue:428-451`): `library_added/removed`, `item_added`, `item_updated`, `item_removed`, `items_updated`, `items_added`, `user_updated`, `user_online`, `user_offline`, `user_stream_update`, `user_session_closed`, `user_item_progress_updated`, `collection_added/updated/removed`, series events, `playlist_added/updated/removed`, `episode_added` (from `PodcastManager`).
- A minimal mobile client needs only `init`, `auth_failed`, `user_updated`, `user_item_progress_updated`, `playlist_*`, and optionally `item_*` / `episode_added` for live library refresh.

---

## 9. Cross-cutting recommendations
1. **Playback core:** build one `@MainActor` player (AVQueuePlayer-based) shared by the phone UI, CarPlay scene, widgets/controls and App Intents. Make the choice between NowPlaying and `MPNowPlayingInfoCenter` once, and use it for iOS, macOS and CarPlay. Gate `AVAudioSession` with `#if os(iOS)`.
2. **Streaming auth:** prefer direct play with the tokenless `/public/session/…` route (server ≥ 2.22). Use `?token=` for covers and downloads. Treat HLS transcode as a fallback that must use a supported authentication mechanism (for example `AVAssetResourceLoaderDelegate` or a tokenised URL); the legacy app's private `AVURLAssetHTTPHeaderFieldsKey` workaround describes old behaviour only and must not be used. The streaming ADR decides the mechanism.
3. **Downloads:** background `URLSession` plus the SwiftData download records, with `.backgroundTask(.urlSession)` as the relaunch hook.
4. **Duo:** use size classes, `ReservedRegion` and `ArrangementView`, and avoid pose-specific logic. Ship Duo screenshots before April 2027.
5. **Auth and sync:** OIDC via `WebAuthenticationSession`, and the Socket.IO `auth` / `init` / `user_item_progress_updated` flow on a hand-rolled websocket client. This needs no SPM dependency.
6. **Dependencies:** ZIPFoundation is the only SPM package recommended (and only if you need cbz or zip).

---

## 10. Gaps and uncertainties
- **`AVURLAssetHTTPHeaderFieldsKey`** is a private, unsupported key. Its behaviour on HLS segment and key requests is unverified.
- I did not verify whether the server accepts `?token=` on `/hls/` paths.
- I did not read the `PlayAudioIntent` parameters (`AppSchema.Intent.audio`).
- The `.xcstrings` JSON sample is from knowledge and unvalidated. Run `xcstringstool` on your generated file.
- The OIDC cookie and session handling is inferred from express-session and `getAuthorizationUrl`. I did not read the callback validation code.
- Whether the server accepts a redirect scheme other than `audiobookshelf://oauth` is unverified.
- iOS interruption and route-change notification details (section 3.2) come from knowledge and were not re-checked against headers.
- CarPlay can't be launched from Xcode 27.2's Device Hub simulator (a known issue; it needs a USB device there). The classic CarPlay simulator routes in §2.7 remain available. Duo layouts can be tested on the iPhone Duo simulator (27.1+; see `xcode-project-and-ci.md` §6), with the caveats in §1.6.
- ZIPFoundation: I did not build it under Swift 6.4 or Xcode 27.2. The Swift 6 / Sendable status of `Archive` is unverified.
- The server's actual Socket.IO ping defaults are assumed to be Socket.IO's stock 25000 / 20000 / 1e6, because the server passes no options. The `connectTimeout` (about 45 s) is from knowledge.
- The default value of `URLSessionWebSocketTask.maximumMessageSize` is from knowledge (about 1 MiB), so set it explicitly.
- Whether the server sends any binary Socket.IO events is not exhaustively audited (the observed ones are JSON).
- The current date appears to be around Nov 2026, so Duo and Xcode 27.x documentation may keep changing.
