# 0004. Navigation architecture for iPhone, iPad, iPhone Duo and Mac

- Status: Accepted
- Date: 2026-11-09
- Issue: #TBD

## Context

The native app needs one navigation model for these targets:

- iPhone.
- iPad, including multiple windows.
- iPhone Duo (folding), in four forms: outer display, open flat, book pose and laptop pose.
- Native macOS (not Catalyst).
- CarPlay, which uses its own template UI.

The deployment target is OS 27.0. We build with Xcode 27.2, Swift 6 and Observation.

The legacy Nuxt app uses a custom shell:

- `layouts/default.vue` stacks an app bar, the page, a fixed audio player and global modals.
- `components/app/Appbar.vue` holds a back button, a library picker, cast, search and a side-drawer button.
- `components/home/BookshelfNavBar.vue` has a second bar with library sections. Book libraries show Home, Library, Series, Collections, Authors and Playlists. Podcast libraries show Home, Latest, Library and Add.
- `components/app/SideDrawer.vue` links to Account, Stats, Local media, Downloads, Settings, Logs, the web client and server switching.

Routes are untyped URL paths such as `/item/:id`, `/series/:id`, `/collection/:id`, `/playlist/:id`, `/media/:id/history` and `/localMedia/...`. The full page list is in [the legacy feature inventory](../research/legacy-feature-inventory.md).

Some platform facts constrain the design (see [the platform API research](../research/platform-apis.md), §1, especially [§1.9](../research/platform-apis.md#19-suggested-adaptation-my-synthesis-not-apple-text)):

- **iPhone Duo is not a pose-aware device for app logic.**
  - The inner display is regular × regular. The outer display is compact width.
  - The app resizes whenever the device opens or closes.
  - Apple says to branch on size classes, reserved regions and the vertical-bar edge, and never on the device or pose.
- **Only system bars are adapted.**
  - On the outer display and in inner landscape, iPhone Duo can show vertical bars. This only applies to bars that belong to `NavigationStack`, `NavigationSplitView` and `TabView`.
  - A custom app bar like the legacy one would not adapt.
- **`ArrangementView` has placement rules.**
  - It is the system two-pane container that aligns with the fold.
  - It must not be placed inside a `List`, `ScrollView`, `NavigationSplitView` or grid.
  - A `NavigationSplitView` or `TabView` must not be placed inside it either.
  - `NavigationStack` and `TabView` must wrap it from the outside.
- Most iPhone Duo APIs require **27.1**, which is above our 27.0 minimum, so they need availability checks.
- `tabViewBottomAccessory`, `ToolbarOverflowMenu`, `.topBarPinnedTrailing` and `defaultTabBarPlacement(.sidebar)` are **unavailable on macOS**.
- CarPlay runs in a separate `CPTemplateApplicationScene`, without SwiftUI. It can launch the app with no window scene, and it is limited to 4 tabs and a template depth of 5.

## Decision drivers

1. **One view tree for every size class.** Opening or closing an iPhone Duo, or resizing an iPad or Mac window, must not tear down navigation state or the player presentation.
2. **System bars only.** Toolbars and tab bars must adapt to iPhone Duo vertical bars, Liquid Glass and the Mac window toolbar without custom code.
3. **`ArrangementView` must be usable** on the player and detail screens without breaking its placement rules.
4. **Typed, testable routing.** Deep links, Handoff and state restoration should all go through the same code path, which can be tested with `swift test`.
5. **One place for the player.** The mini player and full player should stay put while the user browses, on every platform.
6. **Native Mac.** The Mac app should have a sidebar, menus with keyboard shortcuts, a Settings scene and multiple windows.
7. **CarPlay and window scenes share state** (session, library, player and downloads) without sharing navigation.
8. **Minimal availability branching.** The app targets 27.0, but iPhone Duo features need 27.1.

## Options considered

### Option 1: `TabView` with `.sidebarAdaptable` on every platform, with a `NavigationStack` per tab

The root is a `TabView` with `.tabViewStyle(.sidebarAdaptable)`. It has five tabs (Home, Library, Search, Downloads, Account) and a sidebar-only `TabSection` for library sections. Each tab has its own `NavigationStack(path:)`.

The `TabView` shows a tab bar in compact width and a sidebar in regular width and on the Mac.

- Pros
  - One tree for every size class. Folding and unfolding changes only how the tab bar is presented, so per-tab paths survive.
  - The bars belong to `TabView` and `NavigationStack`, so iPhone Duo adapts them to vertical bars automatically.
  - `ArrangementView` can sit inside a `NavigationStack` destination, which is a legal position.
  - Gives us `tabViewBottomAccessory` for the mini player on iOS, and the search tab role.
  - `.defaultTabBarPlacement(.sidebar)` gives the iPhone Duo inner display and iPad a sidebar by default (27.0, iOS only).
  - The same code runs on macOS 15+ as a sidebar.
- Cons
  - Sidebar-only tabs for library sections need a rule for which tab is selected when the window becomes compact.
  - There is no third column. Item detail is pushed onto the stack rather than shown beside the list.
  - The Mac has no `tabViewBottomAccessory`, so it needs its own mini-player placement.
  - The sidebar look on macOS is slightly less customizable than a hand-built `NavigationSplitView` sidebar.

### Option 2: `NavigationSplitView` in regular width, `TabView` in compact width

The root switches containers based on `horizontalSizeClass`.

- Pros
  - Classic three-column iPad and Mac layout (libraries, list, detail).
  - Full control over the sidebar content.
- Cons
  - Two trees. Opening or closing an iPhone Duo, or Slide Over on iPad, swaps the root container, which throws away paths and the presented player unless all state is rebuilt by hand.
  - `ArrangementView` cannot be placed inside `NavigationSplitView`, so the player and detail screens could not use it in the very layouts where it matters most.
  - iPhone Duo puts only the detail column's bar into vertical mode. Toolbar behavior would differ between the two trees.
  - The bottom accessory and the tab search role are lost in regular width.

### Option 3: `TabView` (`.sidebarAdaptable`) on iOS, `NavigationSplitView` on macOS

- Pros
  - Each platform gets its most idiomatic container.
- Cons
  - Two navigation implementations to build, test and keep consistent.
  - On the Mac, `ArrangementView` (anyAppleOS 27.1) could not be used inside the split view's detail column.
  - Routing and restoration code would be forked by platform.

### Option 4: Port the legacy custom shell (app bar, side drawer and bookshelf nav bar)

- Pros
  - A one-to-one port of today's UX.
- Cons
  - Custom bars are ignored by iPhone Duo vertical-bar adaptation and do not get Liquid Glass or the Mac window toolbar.
  - The side drawer is not idiomatic on iPad or Mac and goes against the HIG.
  - All adaptive behavior would have to be built by hand.

## Decision

We choose **Option 1**: a single `TabView` with `.sidebarAdaptable` on every platform. Each tab has a `NavigationStack` driven by a typed `Route`.

### Root structure

```text
WindowGroup(id: "main")                       // iOS + macOS, one Router per window
└─ RootView
   ├─ no session and no downloads → ConnectFlow (port of pages/connect.vue)
   └─ TabView(selection: $router.selectedTab).tabViewStyle(.sidebarAdaptable)
      ├─ Tab "Home"       NavigationStack(path: router.path(.home))
      ├─ Tab "Library"    NavigationStack(path: router.path(.library))
      ├─ TabSection "Browse" .defaultVisibility(.hidden, for: .tabBar)   // sidebar only
      │    Series · Collections · Authors · Playlists   (books)
      │    Latest · Add podcast                         (podcasts)
      ├─ Tab "Downloads"  NavigationStack(path: router.path(.downloads))
      ├─ Tab "Account"    NavigationStack(path: router.path(.account))
      └─ Tab(role: .search) "Search" NavigationStack(...).searchable(...)
      .tabViewSidebarHeader { LibraryPicker }
      iOS:   .defaultTabBarPlacement(.sidebar) .tabBarMinimizeBehavior(.onScrollDown)
             .tabViewBottomAccessory(isEnabled: player.hasSession) { MiniPlayer }
             .fullScreenCover(isPresented: $player.isFullPlayerPresented) { PlayerScreen }
      macOS: .safeAreaInset(edge: .bottom) { MiniPlayer }
      both:  .inspector(isPresented: $player.isQueueInspectorPresented) { QueuePanel }
             .focusedSceneValue(router) .onOpenURL .onContinueUserActivity
WindowGroup("Item", id: "item", for: Route.self)   // "Open in New Window" (iPad, Duo inner, Mac)
Window("Now Playing", id: "now-playing")           // macOS only, single instance
Settings { SettingsView }                          // macOS only
CarPlay scene (UIKit, CPTemplateApplicationSceneDelegate) // no Router, shares AppEnvironment
```

#### Tab mapping

| Tab | Holds |
| --- | --- |
| Home | Personalized shelves. Port of `pages/bookshelf/index.vue`. |
| Library | The library grid. In compact width, a section picker reaches Series, Collections, Authors, Playlists, Latest and Add, which replaces `BookshelfNavBar.vue`. |
| Search | `pages/search.vue`. |
| Downloads | `downloads.vue`, `downloading.vue` and `localMedia/*`. |
| Account | `account.vue`. Stats, Logs, Servers and (on iOS) Settings are pushed from here, which replaces `SideDrawer.vue`. |

#### Compact-width rule

The sidebar-only section tabs need a fallback. If the size class becomes compact while a sidebar-only section is selected, `Router.normalize(for: .compact)` selects `.library` and sets that section as the Library root's selected section. If the size class becomes regular again, nothing changes.

#### Unauthenticated and offline states

- With no server session and no downloaded content, `RootView` shows the connect flow.
- Offline with downloads, the tabs stay visible. Home shows local shelves, as `pages/bookshelf/index.vue` does today.

### Library switching

- The current library is **per scene**: `Router.libraryID`. Two Mac or iPad windows can show different libraries.
- The last-used library for each server and user is saved through ABSData. New windows and CarPlay start from it.
- The picker appears in three places:
  - `tabViewSidebarHeader` in sidebar mode.
  - A toolbar `Menu` item on the Home and Library roots in tab-bar mode. This is a `Label` with an icon and the library name, and it replaces the button in `Appbar.vue`.
  - A **Library** menu on the Mac.
- Switching libraries resets the paths of the library-scoped tabs: Home, Library, the section tabs and Search. Downloads and Account are kept.
- Switching server or user resets every path in every window.

### Typed routes and the Router

```swift
enum AppTab: String, Hashable, Codable, CaseIterable, Sendable {
    case home, library, search, downloads, account
    case series, collections, authors, playlists, latest, addPodcast // sidebar-only sections
}

enum Route: Hashable, Codable, Sendable {
    case item(id: String)                              // pages/item/_id
    case episode(itemID: String, episodeID: String)    // pages/item/_id/_episode
    case series(id: String), author(id: String), narrator(name: String)
    case collection(id: String), playlist(id: String)
    case history(itemID: String)                       // pages/media/_id/history
    case localFolder(id: String), localItem(id: String)
    case downloadQueue, stats, logs, servers
    case settings                                      // iOS only; Mac uses the Settings scene
}

@MainActor @Observable final class Router {
    var selectedTab: AppTab
    var libraryID: String?
    var paths: [AppTab: NavigationPath]   // one NavigationPath per tab
    func path(for tab: AppTab) -> Binding<NavigationPath>
    func open(_ link: DeepLink)           // the only entry point for external navigation
    func normalize(for sizeClass: UserInterfaceSizeClass?)
}
```

**Routes**

- A `Route` carries only server IDs (or ID wrappers from ABSCore). It never carries a model, so routes stay `Codable`, `Sendable` and safe to restore.
- Each `NavigationStack` registers a single `.navigationDestination(for: Route.self)`.
- We use `NavigationPath` rather than `[Route]` because it is what `NavigationStack(path:)` and restoration (`NavigationPath.CodableRepresentation`) expect.
- Only `Route` values may be appended, so `path.codable` is never `nil`.

**Presentations are not routes.** These are owned by the feature that presents them, as sheets, popovers or the inspector:

- Chapters, bookmarks, speed and sleep-timer screens.
- Filter and sort.
- Add to playlist.
- More menus.
- The reader.

**Where the code lives**

- `AppTab`, `Route`, `Router` and `DeepLink` live in `ABSUI` (folder `Navigation/`), so feature screens can use them and `ABSUITests` can test them with `swift test`.
- `RootView`, the scenes, `Commands` and CarPlay live in the app target.

### Deep links and Handoff

The `audiobookshelf` URL scheme is already registered (legacy `ios/App/App/Info.plist`). We keep it.

**URLs**

| URL | Opens |
| --- | --- |
| `audiobookshelf://item/{itemID}[?episode={episodeID}]` | Library tab, then the item (and episode) |
| `audiobookshelf://play/{itemID}[?episode=…&t={seconds}]` | Same as above, then starts playback through `AppEnvironment.player` |
| `audiobookshelf://series/{id}`, `/author/{id}`, `/collection/{id}`, `/playlist/{id}` | The matching route |
| `audiobookshelf://library/{libraryID}` | Switches library |
| `audiobookshelf://search?q=` | Search tab |
| `audiobookshelf://downloads` | Downloads tab |

**Handling URLs**

- `audiobookshelf://oauth` is reserved for the OIDC callback. `ASWebAuthenticationSession` consumes it, and `DeepLink` returns `nil` for it.
- A link may carry `server={connectionID}`. If it differs from the active connection, the app asks before switching.
- There are no universal links, because servers are self-hosted and we control no associated domain.
- `DeepLink.init?(url:)` is a pure parser.
- In the scene that receives the URL, `RootView.onOpenURL` calls `router.open(_:)`.
- `.handlesExternalEvents(preferring:allowing:)` sends links to an existing window instead of creating a new one.

**Handoff**

- Item, episode and player screens publish `.userActivity("org.davidjensenius.Audiobookshelf.item")` with server, library, item, episode and position.
- `.onContinueUserActivity` turns the activity into the same `DeepLink`. The type must be added to `NSUserActivityTypes`.
- App Intents and Spotlight, added later, also produce a `DeepLink`.

### State restoration

**Per scene (`@SceneStorage`)**

- The selected tab.
- `libraryID`.
- Whether the inspector is shown.
- `nav.paths`: JSON-encoded `[AppTab: NavigationPath.CodableRepresentation]`.

**Restore rules**

- Keys include the active server and user ID. A mismatch discards the stored state.
- Paths are written when `scenePhase` becomes `.background`, not on every push.
- A route whose target no longer exists shows `ContentUnavailableView` and is pruned from the path.

**App-wide state**

- The last-used library per server and user is saved through ABSData.
- The playback session is restored by ABSPlayback, not by navigation.
- The full player is not restored as presented. After a relaunch it comes back as the mini player.
- The Mac Now Playing window uses `.restorationBehavior(.disabled)`.

### Player placement

| Platform | Mini player | Full player | Queue, chapters and bookmarks while browsing |
| --- | --- | --- | --- |
| iPhone and Duo outer (compact) | `tabViewBottomAccessory(isEnabled:)`, adapting to `tabViewBottomAccessoryPlacement` (`.expanded` or `.inline`) | `fullScreenCover` → `PlayerScreen` | Sheet. `.inspector` falls back to a sheet in compact width |
| iPad and Duo inner (regular) | Same accessory | Same `fullScreenCover` → `PlayerScreen` (two panes when wide) | `.inspector` trailing column |
| Mac | `.safeAreaInset(edge: .bottom)` bar in each main window | `Window("Now Playing", id: "now-playing")`, opened with `openWindow` | `.inspector`, toggled with `InspectorCommands` |

**Why iOS uses one presentation for every size class**

The issue suggested an inspector for the full player on iPad. We deliberately use the same `fullScreenCover` everywhere on iOS instead.

- If the presentation depended on the size class, opening an iPhone Duo during playback would dismiss the sheet and rebuild the player as an inspector. That would break driver 1 and the HIG guidance to keep hierarchy stable across poses.
- Wide layouts are handled inside `PlayerScreen` with `ArrangementView`.
- The inspector is still used, for the queue panel next to browsing content.

The player model (`AppEnvironment.player`) lives outside every view. Every scene and CarPlay observe it.

### iPhone Duo: outer, flat, book and laptop

**Rules**

- No pose flags and no device checks. Layout only reads:
  - size classes;
  - `GeometryProxy.reservedRegions(kind:options:)`;
  - `EnvironmentValues.toolbarVerticalEdge`;
  - `EnvironmentValues.splitArrangementAxis`.
- `onHingeChange` is used only for optional live effects, never for layout.
- `ArrangementView` is used **only** on `PlayerScreen` and item or episode detail. It sits directly inside a `NavigationStack` destination or the full-screen cover. Its panes own their own `ScrollView`s.
- It is never placed inside a `List`, `ScrollView`, `NavigationSplitView` or grid.

**Arrangement**

```swift
ArrangementView { primary } secondary: { secondary }
    .arrangementViewStyle(.split.axes(.horizontal))
    .splitArrangementLayoutRatio(0.5)
```

- The view splits side by side only when the area is wider than tall: inner landscape, book pose, iPad landscape and Mac windows. Otherwise only the primary pane shows.
- The primary pane reads `splitArrangementAxis`. When it is `nil` (not split), the primary pane shows the secondary content inline (detail) or offers it as a sheet (player).
- **Player panes.** Primary is Now Playing: artwork, title, chapter, scrubber and transport. Secondary is Chapters, Up Next, Bookmarks or Description.
- **Detail panes.** Primary is the cover, metadata and actions. Secondary is the description, chapters, tracks or episodes.

**Laptop pose**

- The player shows primary-only, because the area is taller than wide.
- Now Playing lines up the boundary between artwork and controls with the active `.division` region that is wider than tall. Artwork and title go above the fold, and the scrubber and transport go on the stable lower half.
- This follows the HIG laptop guidance through a reserved region, not a pose check.

**Grids**

- Cover grids compute columns from `reservedRegions(kind: .division, options: .includeInactive)` so the column count stays even and no cover straddles the fold.
- Without a fold region, the grid uses the normal adaptive column count.

**Bars**

- The tab bar and toolbars belong to the system, so iPhone Duo makes them vertical on the outer display and in inner landscape.
- Content insets use the edge from `toolbarVerticalEdge`, and each safe-area edge is handled separately.

**Sheets**

- Chapters, speed and sleep-timer sheets use `.presentationPlacement(.trailing)` on iOS. This gives a vertical sheet on the outer display.

**Availability fallback on 27.0**

- A small `ABSUI` wrapper (`DuoArrangement`) uses `ArrangementView` under `if #available(iOS 27.1, macOS 27.1, *)`.
- Below 27.1 it falls back to `ViewThatFits`: an `HStack` of both panes when wide, otherwise primary-only.
- 27.1 toolbar modifiers are gated inside `@ToolbarContentBuilder` with `if #available`.

#### Sketches

**iPhone (and iPhone Duo outer display, portrait)**

```text
+---------------------------+
| [Library v]       [...]   |  nav bar: Label items, overflow menu
|                           |
|  NavigationStack(path)    |
|  cover grid / list        |
|                           |
| +-----------------------+ |
| | > Title   <<  ||  >>  | |  tabViewBottomAccessory (mini player)
| +-----------------------+ |
| Home Library Dls Account Q|  tab bar; Search uses the .search role
+---------------------------+
  tap mini player -> fullScreenCover PlayerScreen (primary only)
```

**iPhone Duo outer display, landscape (vertical bars)**

```text
+-------------------------------------+---+
|  content (2-column grid)            | Q |  bar on the edge from
|                                     |...|  toolbarVerticalEdge;
|  [mini player]                      | H |  icon-only Label items
+-------------------------------------+---+
```

**iPad and iPhone Duo inner display, open flat (browsing)**

```text
+------------+---------------------------------+--------------+
| [Library v]| < Series    Title        [...]  | Up Next      |
| Home       |                                 | Chapters     |
| Library    |  NavigationStack for the tab    | (inspector)  |
|  Series    |                                 |              |
|  Authors   |  +---------------------------+  |              |
| Downloads  |  | mini player (accessory)   |  |              |
| Account    |  +---------------------------+  |              |
| Search     |                                 |              |
+------------+---------------------------------+--------------+
 sidebar from .sidebarAdaptable + .defaultTabBarPlacement(.sidebar)
```

**iPhone Duo book pose (vertical fold) and inner landscape: PlayerScreen**

```text
+--------------------------++--------------------------+
|  artwork                 ||  Chapters | Up Next      |
|  title / chapter         ||  1. Prologue       0:00  |
|  ----o------------       ||  2. Chapter 1     12:31  |
|   <<   ||   >>   1.0x    ||  ...                     |
+--------------------------++--------------------------+
 primary                  fold                 secondary
 ArrangementView(.split.axes(.horizontal)), ratio 0.5, split aligned to fold
```

**iPhone Duo laptop pose (horizontal fold): PlayerScreen**

```text
+--------------------------+
|        artwork           |  view at a distance
|   title / chapter        |
+==========================+  .division region (fold)
|  ----o-------------      |  touch controls on the stable base
|   <<   ||   >>   1.0x    |
|  [chapters] [sleep] [...]|  secondary opens as a sheet
+--------------------------+
 taller than wide -> primary only; layout boundary = reservedRegions(.division)
```

**Mac**

```text
+------------+-----------------------------------------+-------------+
| [Library v]|  < >  Title                     [...] [i]| Up Next     |
| Home       |                                          | (inspector) |
| Library    |  NavigationStack for the selected tab    |             |
|  Series    |                                          |             |
| Downloads  |                                          |             |
| Account    |                                          |             |
| Search     |                                          |             |
+------------+------------------------------------------+-------------+
|  > Title   <<  ||  >>   ----o------   1.0x      [Now Playing]        |  safeAreaInset(.bottom)
+---------------------------------------------------------------------+
 Separate windows: "Now Playing" (Window), item windows (WindowGroup(for: Route)),
 Settings (cmd-,). Menus: Playback, Go, Library.
```

### Toolbars

- Every toolbar item is a `Label` with a title and a system image. Counts use `.badge` instead of inline text. Spacing uses `ToolbarItemGroup` rather than flexible spacers, because those collapse in vertical bars.
- Primary actions get `.visibilityPriority(.high)`: play/pause, skip, speed, and play on detail screens.
- Rarely used actions go into `ToolbarOverflowMenu`: download, add to playlist, sleep timer, bookmarks, history and share.
  - `ToolbarOverflowMenu` is iOS-only (`#if os(iOS)`).
  - On macOS the same items go into a toolbar `Menu`.
- On 27.1, play/pause gets `.axisBehavior(.verticalPreferred)`, gated inside the builder. The player's close button uses `.topBarPinnedTrailing` (iOS 27.0).
- Legacy app bar mapping:
  - back → system back;
  - library button → library picker;
  - cast → an AirPlay route picker in the player only;
  - search → the Search tab;
  - drawer → the Account tab and the sidebar.

### Mac: menus, Settings and windows

**Scenes**

- `WindowGroup(id: "main")`: File ▸ New Window comes for free. Each window has its own `Router`.
- `WindowGroup(id: "item", for: Route.self)`: "Open in New Window" from context menus. This is also used on iPad and the iPhone Duo inner display. It is hidden when `supportsMultipleWindows` is false, because new windows can't be created from the iPhone Duo outer display.
- `Window("Now Playing", id: "now-playing")`.
- `Settings { SettingsView }`, which is the same `SettingsView` that iOS pushes as `Route.settings`.

**Commands** (`.commands` on the main `WindowGroup`, which also fills the iPadOS menu bar)

- `SidebarCommands` and `InspectorCommands`.
- **Playback**: Play/Pause (Space), skip back and forward, previous and next chapter, speed, sleep timer, Show Now Playing.
- **Go**: Home through Account (⌘1–⌘5), Back (⌘[).
- **Library**: one item per library (⌥⌘1–⌥⌘9).
- The exact shortcuts are finalized in the Mac issue.

**How commands reach state**

- Navigation commands use `@FocusedValue(Router.self)`, which reads the key window's router published with `.focusedSceneValue(router)`.
- Playback commands talk to `AppEnvironment.player` directly.

### CarPlay and `AppEnvironment`

`AppEnvironment` is defined by the architecture document (P0-05). It is an app-wide, `@MainActor`, scene-independent object, created lazily as `AppEnvironment.shared`, so the first caller creates it:

- `App.init` creates it and injects it with `.environment(_:)`.
- `CarPlaySceneDelegate` reads `AppEnvironment.shared` on connect, because CarPlay can launch the app without a window scene.

It owns these services:

- Session and account.
- The library repository and cache.
- The last-used library.
- `PlayerModel`.
- Downloads.
- Settings.

It does **not** own a `Router`. Navigation is per window scene.

**CarPlay templates**

- CarPlay builds its own tree:
  - `CPTabBarTemplate` with at most 4 tabs, for example Continue, Library and Downloads.
  - `CPListTemplate`s up to a depth of 5.
  - `CPNowPlayingTemplate.shared`.
- CarPlay starts playback through `PlayerModel`. Every window's mini player appears because it observes the same model.
- CarPlay never changes window routers, and windows never push CarPlay templates.
- No `Route` or `DeepLink` type is used in CarPlay.

### APIs and minimum versions

All entries were checked in the Xcode 27.2 iPhoneOS and MacOSX SDK `SwiftUI.swiftinterface` and `SwiftUICore.swiftinterface`.

| API | Availability | Used for |
| --- | --- | --- |
| `ArrangementView`, `.arrangementViewStyle`, `.split` (`.axes`), `.splitArrangementLayoutRatio`, `EnvironmentValues.splitArrangementAxis` | **anyAppleOS 27.1** | Player and detail panes |
| `ReservedRegion`, `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)`, `.division`, `.includeInactive` | **anyAppleOS 27.1** | Fold-aware grids, laptop player layout |
| `EnvironmentValues.toolbarVerticalEdge` | **anyAppleOS 27.1** | Edge-specific insets |
| `View.toolbarVerticalBehavior(_:)` | **anyAppleOS 27.1** | Opting out per toolbar, if needed |
| `ToolbarContent.axisBehavior(_:)` (`.verticalPreferred` and `.horizontalOnly` are macOS-unavailable) | **anyAppleOS 27.1** | Play/pause in vertical bars |
| `View.toolbarVerticalCompressionBehavior(_:)` (non-automatic values are iOS 27.1 only) | **anyAppleOS 27.1** | Player toolbar compared with tab bar, if needed |
| `View.onHingeChange(isEnabled:_:)`, `DeviceHingeContext` | **anyAppleOS 27.1** | Optional live effects only |
| `ToolbarContent.visibilityPriority(_:)` | iOS 27.0, macOS 26.1 | Toolbar priority |
| `ToolbarOverflowMenu`, `View.toolbarOverflowMenu(content:)` | iOS 27.0; macOS unavailable | Rare actions |
| `ToolbarItemPlacement.topBarPinnedTrailing` | iOS 27.0; macOS unavailable | Player close button |
| `View.defaultTabBarPlacement(_:)` (`.sidebar` is macOS-unavailable) | anyAppleOS 27.0 | Sidebar default on iPad and iPhone Duo inner display |
| `View.presentationPlacement(_:)` (`.leading` / `.center` / `.trailing` are iOS only) | anyAppleOS 27.0 | Vertical sheets on iPhone Duo outer display |
| `View.tabViewBottomAccessory(content:)` / `(isEnabled:content:)`, `tabViewBottomAccessoryPlacement` | iOS 26.0 / 26.1; macOS unavailable | Mini player |
| `View.tabBarMinimizeBehavior(_:)` | iOS 26.0, macOS 26.0 | Tab bar minimization |
| `.sidebarAdaptable`, `Tab`, `TabSection`, `TabRole.search`, `tabViewSidebarHeader` | iOS 18.0, macOS 15.0 | Root |
| `View.inspector(isPresented:content:)`, `InspectorCommands` | iOS 17.0, macOS 14.0 | Queue panel |
| `focusedSceneValue(_:)` (Observable), `@FocusedValue(_: Type)` | iOS 17.0, macOS 14.0 | Commands |
| `restorationBehavior(_:)` | iOS 18.0, macOS 15.0 | Now Playing window |
| `NavigationPath.CodableRepresentation`, `WindowGroup(id:for:)`, `openWindow(id:value:)`, `SceneStorage`, `onOpenURL`, `userActivity` / `onContinueUserActivity`, `handlesExternalEvents` | ≤ iOS 16, macOS 13 | Routing and restoration |

**Minimum version per API**

- Every API marked **27.1** is above the 27.0 deployment target and is gated with `if #available(iOS 27.1, macOS 27.1, *)` or `@available(iOS 27.1, macOS 27.1, *)`.
- Every API that is unavailable on macOS is wrapped in `#if os(iOS)`.
- Everything else is available at 27.0.

## Consequences

**Positive**

- One root view tree works on every platform. Folding, unfolding, window resizing and Slide Over keep tab selection, per-tab paths and the player presentation.
- iPhone Duo vertical bars, Liquid Glass and Mac toolbars come from the system.
- Routing, deep links, Handoff and restoration share one `DeepLink → Router.open` path that can be unit tested.
- CarPlay stays decoupled and reuses services through `AppEnvironment`.

**Negative and risks**

- There is no three-column browse layout on iPad or Mac. Item detail replaces the list instead of sitting beside it.
  - Mitigations: "Open in New Window" and the inspector.
  - Revisit if users ask for a column layout. That would be a new ADR, and the detail column could not host `ArrangementView`.
- The Mac mini player is custom (`safeAreaInset`), and its placement differs from iOS.
- Sidebar-only section tabs need `Router.normalize(for:)` and tests.
- Two code paths exist below 27.1 for arrangement and toolbar axis behavior. They should be removed when the minimum OS moves to 27.1.
- A `NavigationPath` cannot be inspected element by element. Tests check `DeepLink` parsing (to `[Route]`) and the `Router` restoration round trip, not the internals of the path.

**Follow-ups**

- Add `NSUserActivityTypes` to the app's `Info.plist`.
- The shell issue implements `AppTab`, `Route`, `Router`, `DeepLink` and `DuoArrangement` in ABSUI, with tests.
- The player UI, Mac and CarPlay issues follow the placements above.

## Validation

**Verified for this ADR**

- **SDK check.** Every API in the table was looked up in the Xcode 27.2 `iPhoneOS27.2.sdk` and `MacOSX27.2.sdk` swiftinterfaces, with its `@available` attributes.
- **Throwaway spike** (`/tmp/abs-spike-nav`, deleted afterwards).
  - The spike contained the proposed `RootView`: `TabView`, `TabSection`, search role, sidebar header, bottom accessory, `fullScreenCover`, inspector, `focusedSceneValue`, `onOpenURL`, `onContinueUserActivity` and `SceneStorage`.
  - It also contained `Router` with `NavigationPath.CodableRepresentation` restoration, `DeepLink`, the `DuoArrangement` wrapper, a fold-aware grid and 27.1 toolbar modifiers.
  - The app scenes were included as well: `WindowGroup(for: Route.self)`, `Window`, `Settings`, `commands` with `@FocusedValue(Router.self)`, and `restorationBehavior`.
- **Typecheck results.** The spike typechecked with no errors in Swift 6 mode:
  - `xcrun --sdk iphonesimulator swiftc -typecheck -parse-as-library -swift-version 6 -target arm64-apple-ios27.0-simulator`;
  - `xcrun --sdk macosx swiftc -typecheck -parse-as-library -swift-version 6 -target arm64-apple-macos27.0`.
- **`ArrangementView` without a gate fails.** Using it without `if #available` at a 27.0 target fails with "'ArrangementView' is only available in iOS 27.1 or newer". This confirms the gating requirement.
- **Gated toolbar items typecheck.** `if #available(iOS 27.1, *)` inside a `@ToolbarContentBuilder` around `.axisBehavior(.verticalPreferred)` typechecks at a 27.0 target.

**Assumed (not yet verified at runtime)**

These must be checked in the iPhone Duo simulator (Xcode 27.2) and on iPad and Mac when the shell is implemented:

- `tabViewBottomAccessory` behaves well with vertical tab bars on the iPhone Duo outer display and in sidebar mode.
- `splitArrangementAxis` is `nil` when `ArrangementView` shows the primary pane only.
- `.split.axes(.horizontal)` shows primary-only in laptop pose.
- `.defaultVisibility(.hidden, for: .tabBar)` section tabs behave as described when the window becomes compact.
- iPhone Duo always runs iOS 27.1 or later, so the 27.0 fallback is only seen on iPad and iPhone.
- **Simulator caveats.** Black screenshots appear for minutes after boot. VoiceOver is unavailable on iPhone Duo in 27.2.

**Planned checks**

- `ABSUITests` covers `DeepLink` parsing, including `oauth` being rejected.
- `ABSUITests` covers the `Router` paths round trip through `CodableRepresentation`, `normalize(for:)`, and path resets on library and server switches.
- A manual pass covers iPhone, iPad and iPhone Duo (outer, flat, book, laptop and tent) and Mac against the sketches above.

## References

- [Platform API research](../research/platform-apis.md), §1 (iPhone Duo), §1.9 (suggested adaptation) and §2 (CarPlay)
- [Legacy feature inventory](../research/legacy-feature-inventory.md)
- Legacy: `layouts/default.vue`, `components/app/Appbar.vue`, `components/app/SideDrawer.vue`, `components/home/BookshelfNavBar.vue`, `plugins/init.client.js` (`appUrlOpen`), `ios/App/App/Info.plist` (`CFBundleURLSchemes`)
- Xcode 27.2 SDK: `SwiftUI.swiftinterface` and `SwiftUICore.swiftinterface` (iPhoneOS27.2.sdk and MacOSX27.2.sdk)
- Apple: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Designing for iPhone Duo (HIG)](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview), [ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion), [toolbarVerticalEdge](https://developer.apple.com/documentation/swiftui/environmentvalues/toolbarverticaledge)
