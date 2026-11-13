# 0004. Navigation architecture for iPhone, iPad, iPhone Duo and Mac

- Status: Accepted
- Date: 2026-11-09
- Issue: #41 (P3-01)

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
- `components/home/BookshelfNavBar.vue` has a second bar with library sections. Book libraries show Home, Library, Series, Collections and Authors. Podcast libraries show Home, Latest, Library and Add (admins only). Playlists is added for **both** types when the user has playlists (`BookshelfNavBar.vue` lines 116–125, outside the book/podcast branch), and `pages/playlist/_id.vue` plays podcast episodes as well as books.
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
  - Each `NavigationStack(path:)` can bind to a plain typed `[Route]` array. The navigation state is ordinary `Codable` data with no SwiftUI import, so it can be inspected and tested directly.
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
      ├─ Tab "Home"       NavigationStack(path: $router[path: .home])      // [Route]
      ├─ Tab "Library"    NavigationStack(path: $router[path: .library])
      ├─ TabSection "Browse" .defaultVisibility(.hidden, for: .tabBar)   // sidebar only
      │    Series · Collections · Authors               (books)
      │    Latest · Add podcast (admins)                (podcasts)
      │    Playlists                                    (both, if the user has any)
      ├─ Tab "Downloads"  NavigationStack(path: $router[path: .downloads])
      ├─ Tab "Account"    NavigationStack(path: $router[path: .account])
      └─ Tab(role: .search) "Search" NavigationStack(...).searchable(...)
      .tabViewSidebarHeader { LibraryPicker }
      iOS:   .defaultTabBarPlacement(.sidebar) .tabBarMinimizeBehavior(.onScrollDown)
             .tabViewBottomAccessory(isEnabled: playerVM.hasSession) { MiniPlayer }
             .fullScreenCover(isPresented: $router.isFullPlayerPresented) { PlayerScreen }
      macOS: .safeAreaInset(edge: .bottom) { MiniPlayer }
      both:  .inspector(isPresented: $router.isQueueInspectorPresented) { QueuePanel }
             .focusedSceneValue(router) .onOpenURL .onContinueUserActivity
      // Presentation flags live on the per-scene Router; playerVM is the shared PlayerViewModel.
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

The sidebar-only section tabs need a fallback. If the size class becomes compact while a sidebar-only section is selected (for example on an iPhone Duo fold or a narrowed iPad window), `Router.normalize(isCompact: true)` keeps the user on the same screen:

1. It sets that section (for example Series) as the Library root's selected section (`Router.librarySection`), so the Library root now shows what the section tab's root showed.
2. It moves the section's path into Library: `paths[.library] = paths[.series]`. This **replaces** any existing Library path. That older Library path was not visible, and keeping it would put an unrelated screen on top.
3. It clears `paths[.series]` and selects `.library`.

The visible destination (for example an item pushed from Series) is therefore unchanged, and Back returns to the Series list in the Library root. If the size class becomes regular again, nothing moves back: the user stays in Library with that section selected, and the Series tab starts at its root. Router tests cover the transfer and the replacement.

#### Unauthenticated and offline states

- With no server session and no downloaded content, `RootView` shows the connect flow.
- Offline with downloads, the tabs stay visible. Home shows local shelves, as `pages/bookshelf/index.vue` does today.

### Library switching

- The current library is **per scene**: `Router.libraryID`. Two Mac or iPad windows can show different libraries.
- The last-used library for each server and user is saved in `AppSettings` (App Group `UserDefaults`, P1-05 #28), not in SwiftData. New windows and CarPlay start from it.
  - A library switch in any window updates it.
  - CarPlay's own library switch also updates it.
  - CarPlay's switch never changes an open window's `Router.libraryID`.
- `LibraryStore` (P3-05 #45) is shared by all scenes and keyed by library ID. It holds the libraries list, filter data and caches, and owns **no** "current library". Each scene passes its `Router.libraryID` to it.
- The picker appears in three places:
  - `tabViewSidebarHeader` in sidebar mode.
  - A toolbar `Menu` item on the Home and Library roots in tab-bar mode. This is a `Label` with an icon and the library name, and it replaces the button in `Appbar.vue`.
  - A **Library** menu on the Mac.
- Switching libraries resets the paths of the library-scoped tabs: Home, Library, the section tabs and Search. Downloads and Account are kept.
- Switching between a book and a podcast library also repairs the selection, because the two have different sections (see Context):
  - Supported sections: book libraries have Series, Collections, Authors and Playlists; podcast libraries have Latest, Add podcast (admins only) and Playlists. Playlists is valid for both types, so it is kept across a book ↔ podcast switch.
  - If `selectedTab` is a section the new library does not have (for example `.authors` in a podcast library, or `.latest` in a book library), `Router` selects `.library`.
  - If the Library root's selected section is unsupported, it resets to that library's default section (the grid).
  - Home, Library, Search, Downloads and Account exist for both types and are kept.
- Switching server or user resets every path in every window. `Router.resetForIdentityChange(serverID:userID:)` takes the new IDs, because the router's identity decides which snapshots it accepts.

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

// ABSAppModel/Navigation/Router.swift — imports Foundation and Observation only, no SwiftUI
@MainActor @Observable final class Router {
    var selectedTab: AppTab
    var libraryID: String?
    var librarySection: AppTab?           // Library root's selected section; nil = default grid
    var paths: [AppTab: [Route]]          // one typed path per tab
    var isFullPlayerPresented = false     // per-scene presentation state,
    var isQueueInspectorPresented = false // never stored on the shared player
    subscript(path tab: AppTab) -> [Route] { get set }  // NavigationStack binds $router[path: tab]
    var snapshot: Snapshot { get set }    // Codable: server/user IDs, tab, libraryID, librarySection, paths, inspector flag
    func open(_ link: DeepLink)           // the only entry point for external navigation
    func normalize(isCompact: Bool)       // the view passes horizontalSizeClass == .compact
}
```

**Routes**

- A `Route` carries only server IDs (or ID wrappers from ABSCore). It never carries a model, so routes stay `Codable`, `Sendable` and safe to restore.
- Each `NavigationStack(path:)` binds to that tab's `[Route]` and registers a single `.navigationDestination(for: Route.self)`.
- We use a typed `[Route]` per tab instead of `NavigationPath` for three reasons:
  - It is plain `Codable` data, so `ABSAppModel` needs no SwiftUI import.
  - Tests can inspect and compare it element by element.
  - Restoration is plain JSON, with no `CodableRepresentation`.
- The subscript is needed because `$router.paths[tab, default: []]` does not compile: the `default:` autoclosure is not a `Hashable` key-path index.

**Presentations are not routes.** These are owned by the feature that presents them, as sheets, popovers or the inspector:

- Chapters, bookmarks, speed and sleep-timer screens.
- Filter and sort.
- Add to playlist.
- More menus.
- The reader.

**Where the code lives**

- `AppTab`, `Route`, `Router`, `DeepLink`, and the scene rules `SceneNavigation` and `SceneContent` (when a scene may open a link or save, and what its root shows for the session gate) live in **ABSAppModel**, in `ABSAppModel/Navigation/` (for example `Router.swift`, per P3-04 #44). They are tested with `swift test` in its test target.
- `DuoArrangement` and the other navigation-related views and modifiers stay in **ABSUI**.
- `RootView`, the scenes, `Commands` and CarPlay live in the app target.

### Deep links and Handoff

The legacy app registers the `audiobookshelf` URL scheme (`ios/App/App/Info.plist`). We keep it, and the new app registers it in `Audiobookshelf/Info.plist` as one `CFBundleURLTypes` entry (`CFBundleURLName` is the bundle ID, role `Editor`, scheme `audiobookshelf`). The same plist feeds the iOS and macOS builds, and `AppEnvironmentTests` checks the entry.

**Scheme collision.** The legacy Capacitor app registers the same scheme. If both apps are installed on one device, iOS does not define which app receives `audiobookshelf://` URLs, and that includes the OIDC callback.

- OIDC is not affected, because `ASWebAuthenticationSession` with `.customScheme("audiobookshelf")` delivers the callback to the session that started it.
- For other links, the legacy app may open instead of the new one.
- We accept this, because the new app replaces the legacy one under the same scheme.
- The onboarding and release notes (P3-04 #44) state that the legacy app should be removed.
- We do not add a second scheme.

**URLs**

| URL | Opens |
| --- | --- |
| `audiobookshelf://item/{itemID}[?episode={episodeID}]` | Library tab, then the item (and episode) |
| `audiobookshelf://play/{itemID}[?episode=…&t={seconds}]` | Opens the item, then follows the play-link rules below. Playback goes through `PlayerViewModel` / `PlaybackCoordinator` |
| `audiobookshelf://series/{id}`, `/author/{id}`, `/collection/{id}`, `/playlist/{id}` | The matching route |
| `audiobookshelf://library/{libraryID}` | Switches library |
| `audiobookshelf://search?q=` | Search tab |
| `audiobookshelf://downloads` | Downloads tab |

**Handling URLs**

- `audiobookshelf://oauth` is reserved for the OIDC callback. `ASWebAuthenticationSession` consumes it, and `DeepLink` returns `nil` for it.
- A link may carry `server={connectionID}`. If it differs from the active connection, the app asks before switching. The ID is the connection's local UUID, which each device makes for itself, so it is meaningful only for a link made and used on the same device; it is never put in a Handoff payload (see "Handoff").
- There are no universal links, because servers are self-hosted and we control no associated domain.
- `DeepLink.init?(url:)` is a pure parser.
- In the scene that receives the URL, `RootView.onOpenURL` hands the link to the scene's host, which calls `router.open(_:)` once the scene has restored its saved navigation, so the restore can't wipe the link.
  - Only a ready session's shell takes the link. During an account switch the outgoing shell doesn't, so the incoming account's shell opens it.
  - A link is never kept while signed out, while signing out or without a store: one that arrives then is dropped. One already waiting when the account it arrived under ends is dropped too, because each waiting link carries `SessionLifecycle.linkEpoch`, which advances when the gate becomes signing out, switching, connect or store unavailable, and the host is handed the link only while the epoch is unchanged. A view can miss a short-lived gate, so the epoch decides, not the gate it rendered. A link that arrives during a switch carries the epoch after the switch began, so it opens for the incoming account.
- `RootView` applies `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])`, so URLs and continued activities go to an existing window instead of creating a new one. On macOS, repeated `open audiobookshelf://downloads` keeps one window with the modifier, and opens another window each time without it.

**URL format** (`ABSAppModel/Navigation/DeepLink.swift`)

- The legacy app handled only `audiobookshelf://oauth`, so there is no older link format to stay compatible with.
- The kind is the host (`audiobookshelf://item/li_1`); a URL without a host gives `nil`. Scheme, kind and query names are case-insensitive; IDs are not.
- Each kind takes exactly one ID segment (`search` and `downloads` take none); one trailing `/` is ignored. A missing ID, an empty or extra segment (`item//li_1`, `search//`), an unknown kind or `oauth` gives `nil`.
- IDs (including `episode=` and `server=`) must not be blank, `.` or `..`, contain control characters, or exceed 256 characters; `q=` is capped at 1,024. Otherwise the link is `nil`.
- Path segments and query names and values are percent-decoded (`%73erver=` is `server=`), and `+` in a query name or value is a space. A name or value that doesn't decode gives `nil`. Empty `episode=`, `q=` and `t=` count as absent, but an empty or unreadable `server=` gives `nil` rather than falling back to the active server. The first of a repeated parameter wins.
- `t=` is seconds (`5025`, `5025.5`) or a clock time (`1:23:45`, `83:45`), at most 10,000,000 seconds. Anything else, including negative values, is ignored and the link still opens the item.
- `Router.open(_:)` opens item, series, author, collection and playlist links in the Library tab, pushing onto its path. `library` calls `requestLibrary(id:)`. `search` selects Search at its root and sets `pendingSearchQuery`. A `server=` that isn't the router's server only sets `pendingServerSwitch`.
- `PlayLinkDecision` gives `.openOnly` for the item that is playing (or buffering), `.confirmResume(startTime:)` for the loaded but paused item, and `.confirmPlay(startTime:)` otherwise. A `play/{podcastID}` link without an episode has nothing to play; the item screen treats it as open-only.

**Play links never start playback silently.** Any app or web page can open a URL, so `play/` links are limited:

- If the link targets the item (and episode) that is **currently playing**, it is a no-op apart from opening the item screen. It never seeks, even when the link carries `t=`.
- In every other case, including an item that is loaded but paused, the item screen opens with a confirmation: "Play *title*?" (or "Resume *title*?" for the paused session), which shows `t=` as "from 1:23:45" if present. For the paused session with `t=`, the UI may also offer "Resume at current position".
  - Nothing starts, resumes, replaces the current session or seeks until the user confirms.
- Siri, Shortcuts and widgets start playback through App Intents (P5-09 #86, P5-10 #87), not through URLs, so they do not need this confirmation.

**Handoff**

- The item and episode screens publish `.userActivity("org.davidjensenius.Audiobookshelf.item")` with the payload below (`HandoffPublishing`, applied in `RouteDestination`; #504). The player doesn't publish yet (#219).
  - Only the screen on top of the selected tab's stack publishes, as for ⌘R. On macOS a hidden tab's screens stay appeared, and a covered screen stays in its stack, so neither of those publishes.
  - The activity names the active account only while it's the account of the shell on screen. During a switch the outgoing shell publishes nothing, because its IDs belong to the outgoing account. With no active connection, or with IDs a receiver would reject, nothing is published either.
  - The activity is eligible for Handoff only. `isEligibleForSearch` and `isEligibleForPrediction` stay off: Spotlight and Siri suggestions come from App Intents and entities (P5-10 #87), not from browsing history.
- `RootView.onContinueUserActivity` reads the activity with `HandoffActivity(userInfo:)` and resolves its account (below) before the link joins the links from `onOpenURL`.
- The activity type is listed in `NSUserActivityTypes` in `Audiobookshelf/Info.plist`, which the system requires before it delivers the activity. `AppEnvironmentTests` checks it.
- The intents and entities side of Handoff is in P5-10 #87.
- App Intents, added later, also produce a `DeepLink`.

| `userInfo` key | Type | Meaning |
| --- | --- | --- |
| `item` | string, required | The library item's ID |
| `episode` | string | The podcast episode's ID. Empty counts as absent |
| `position` | number | Seconds, from 0 to 10,000,000. An activity with a position becomes a `play` link, which asks before it plays. A value that isn't a number in range (a Boolean isn't one) is ignored, and the activity opens the item |
| `library` | string | Not used. The item opens in the active library |

IDs follow the URL rules. A present but invalid `item` or `episode` rejects the activity.

**Account identity.** The only ID this device has for a server is its local connection UUID, which each device makes for itself, so it means nothing on another device. It is **never published**. The payload names the account by the server's address and the user's ID instead, which are the same on every device signed in to it.

| `userInfo` key | Type | Meaning |
| --- | --- | --- |
| `serverAddress` | string | The server's normalized address (`ServerAddress.description`, for example `https://abs.example.com/audiobookshelf`) |
| `userID` | string | The user's ID on that server. Follows the ID rules |

- The two keys are additive: a receiver that predates them ignores them and opens the item on its active account.
- They come as a pair. Neither present means a payload from before they were added, which opens on the active account. Only one present, either empty or not a string, an address that isn't already in normalized form, or an invalid user ID rejects the activity, so it never opens on whichever account happens to be active. Other keys, known or not, are ignored.
- `DeepLink.init?(handoff:)` ignores a `server` entry, whatever it holds.
- `HandoffActivity(userInfo:)` reads the link and the account (`HandoffAccount`). Before `Router.open(_:)`, `HandoffActivity.resolve(using:)` asks the `AccountSessionSource` for the connection signed in to that account (`connectionID(for:)`). `AccountManager` matches its saved connections on the normalized address and the exact user ID, skipping connections that were signed out of or disconnected, and those without a saved session (`hasSession(_:)`): an expiry deletes the tokens but keeps the connection without a sign-out, so a switch to it would fail. The most recently used one left wins. The lookup is `async` because it reads the Keychain. The protocol's default matches nothing.
  - A match gives the link with `serverID` set to that connection. If it's the active connection the router opens it; otherwise the router's `pendingServerSwitch` asks before switching, as for a URL with `server=`.
  - No match gives `accountNotSignedIn`: nothing opens, on no account, and the scene shows an alert saying that account isn't signed in on this device (`MessageHandoffAccountNotSignedIn`).
  - Two servers, or two users on one server, resolve to their own connections.
- The app's `AccountSessionAdapter` forwards `connectionID(for:)` to `AccountManager` (#504). The scene resolves through `SessionLifecycle.resolve(_:)`, which asks the same source the lifecycle follows.
- The scene resolves after the launch: `SessionLifecycle.resolve(_:)` awaits `start()` before the lookup, because on a cold launch the activity can arrive before `AccountManager` has loaded its saved connections. The activity keeps the arrival, gate and epoch from when it arrived, so if the launch ends signed out it does nothing, as a URL received then would.
- The lookup is asynchronous, so `SceneLinks` orders the links by arrival. A Handoff activity reserves its place when it arrives (`reserveArrival()`) and is kept with the gate and link epoch from that moment.
  - It is the newest link even if it turns out to open nothing, so on arrival it drops the waiting link and a confirmed switch's link, and the host drops the server switch its dialog or router asks about (`handoffArrivals`, `ServerSwitchPrompt.supersede(in:)`).
  - Its result is stale, and does nothing, if another link arrived while it resolved (the newer link wins) or the session changed (the epoch moved on). That holds for both results: a stale link isn't kept, not even for a confirmed switch's next account, and a stale `accountNotSignedIn` shows no alert.
- Publishing from the player is a follow-up (#219).

**Spotlight**

- `RecentItemsDonor` (#87) indexes each account's 20 most recently played items, associated with their `BookEntity` or `PodcastEpisodeEntity`. Each item's domain is its account's connection ID. Its identifier is its `MediaKey`, so playing it again updates it.
- An account's items are deleted when it signs out, is removed, or its credentials expire, and when a switch to it ends signed out. A switch to another account keeps them.
- A tapped result reaches `RootView.onContinueUserActivity(CSSearchableItemActionType)`. `DeepLink(spotlightIdentifier:)` turns it into an item or episode link with `server=` set to the item's own connection, so a result from another signed-in account asks before switching. The connection ID is local, but so is the Spotlight index.

### State restoration

**Per scene (`@SceneStorage`)**

`Router.snapshot` is stored as JSON `Data` under an identity-scoped key: `nav.snapshot.<serverID>.<userID>`. `RootView` builds the key from the active session and hosts the stack in a child view initialised with that key and `.id(identity)`, so a server or user switch reads a different entry. The snapshot is a `Codable` struct of:

- `serverID` and `userID`.
- The selected tab.
- `libraryID`.
- `libraryKind` (book or podcast), the type of `libraryID`, so `librarySection` can be validated on restore before the libraries load.
- `librarySection`, the Library root's selected section, so a restored compact scene keeps its Series (or other section) context at the root and when going Back from a restored detail.
- The `[AppTab: [Route]]` paths.
- Whether the queue inspector is shown.

`isFullPlayerPresented` is deliberately left out.

**Restore rules**

- The key and the stored `serverID`/`userID` must both match the active session. On a mismatch (for example after the server re-issues a user ID) the snapshot is discarded and the scene starts from the defaults.
- `librarySection` is restored **before** the paths. It is validated against the restored library's type (book or podcast), using the same rule as library switching: an unsupported or unknown section falls back to the default grid (`nil`).
- The snapshot is written to scene storage as the navigation changes, and also, as a backup, whenever the scene leaves `.active` (`.inactive` as well as `.background`, because macOS can quit a scene without `.background`). It is never written before the restore has finished, which would replace the saved snapshot with the defaults. A link that the restore opens is written too.
- A route whose target no longer exists shows `ContentUnavailableView` and is pruned from the path.

**App-wide state**

- The last-used library per server and user is saved in `AppSettings`.
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

**Shared player, per-scene presentation**

- The playback object is `PlaybackCoordinator` (ABSPlayback, P2-06a #52). It lives in `AppEnvironment`, outside every view.
- Views observe it through a shared `@MainActor @Observable` `PlayerViewModel` in ABSAppModel, which wraps it. Every window scene and CarPlay see the same playback state.
- Whether the full player or the queue inspector is shown is **per scene**: `Router.isFullPlayerPresented` and `Router.isQueueInspectorPresented`. It is never on `PlaybackCoordinator` or `PlayerViewModel`.
  - Opening the player in one window, or from CarPlay, does not present it in other windows.
  - The Mac Now Playing window is a scene of its own, opened with `openWindow`.

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
- *Amended by #84:* an active vertical `.division` splits the player at any size class, so a compact window across the fold never gets the column, whose scrubber and transport would cross the hinge.
- **Player panes.** Primary is Now Playing: artwork, title, chapter, scrubber and transport. Secondary is Chapters, Up Next, Bookmarks or Description.
- **Detail panes.** Primary is the cover, metadata and actions. Secondary is the description, chapters, tracks or episodes.
- *Amended by #85:* item and episode detail split only across a `.division` running down through them, inactive or not, so folding and unfolding doesn't rebuild them (`DetailArrangement`). Each side needs room for the text column (320 pt) inside its own safe-area edge, such as a sidebar's or a vertical toolbar's; otherwise, and on an iPad or a Mac, the detail keeps its scroll view. The primary is the cover, title, actions, progress and metadata (an episode's cover, title, Play and progress); the secondary is the description and the chapter, track and ebook tables (the show notes). As for the player, there is no 27.0 `ViewThatFits` fallback: below iOS 27.1 and on macOS the detail is unchanged.

**Laptop pose**

- The player shows primary-only, because the area is taller than wide.
- Now Playing lines up the boundary between artwork and controls with the active `.division` region that is wider than tall. Artwork and title go above the fold, and the scrubber and transport go on the stable lower half.
- This follows the HIG laptop guidance through a reserved region, not a pose check.
- *Amended by #84:* the player does this with an `ArrangementView` in the `.overlay` style, not `.split`. The controls are the primary, with `overlayArrangementEdge(.bottom)`. The artwork and title are the secondary. Folded, the overlay puts the secondary on the top half and the primary on the bottom half, clear of the hinge. `.split` would put the primary (the controls) on top.
- Until the first geometry arrives, the player keeps the column layout, so laptop pose doesn't flash the split first.

**Grids**

- Cover grids compute columns from `reservedRegions(kind: .division, options: .includeInactive)` so the column count stays even and no cover straddles the fold.
- Without a fold region, the grid uses the normal adaptive column count.
- *Amended by #85:* `ItemGrid` puts as many equal columns on each side as the narrower side fits, with a gap over the fold. The count comes from a fixed 32-point reservation over the fold, so it is the same flat and folded. A side too narrow for one card stays empty, so the other side's count can be odd. When neither side fits one, narrower cards still keep to their sides. Below iOS 27.1 and on macOS the grid is unchanged.

**Bars**

- The tab bar and toolbars belong to the system, so iPhone Duo makes them vertical on the outer display and in inner landscape.
- Content insets use the edge from `toolbarVerticalEdge`, and each safe-area edge is handled separately.

**Sheets**

- Chapters, speed and sleep-timer sheets use `.presentationPlacement(.trailing)` on iOS. This gives a vertical sheet on the outer display.

**Availability fallback on 27.0**

- A small `ABSUI` wrapper (`DuoArrangement`) uses `ArrangementView` under `if #available(iOS 27.1, macOS 27.1, *)`.
- Below 27.1 it falls back to `ViewThatFits`: an `HStack` of both panes when wide, otherwise primary-only.
- 27.1 toolbar modifiers are gated inside `@ToolbarContentBuilder` with `if #available`.
- *Amended by #84 for the player:* the player's arrangements stay in the app (`PlayerLayout`, `DuoPlayerLayouts.swift`), not in an ABSUI `DuoArrangement`, and have **no** 27.0 `ViewThatFits` fallback. #84 requires the player on iOS 27.0 (and on macOS) to stay exactly as it was, a single column, so below 27.1 there is nothing to fall back to. The 27.1 toolbar pieces are gated by `if #available` in the view rather than in the toolbar builder.

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
- Playback commands call `PlayerViewModel` / `PlaybackCoordinator` from `AppEnvironment`.
- "Show Now Playing" sets the focused router's `isFullPlayerPresented` on iOS, and calls `openWindow(id: "now-playing")` on the Mac.

### CarPlay and `AppEnvironment`

`AppEnvironment` is defined by the architecture document (P0-05). It is an app-wide, `@MainActor`, scene-independent object, created lazily as `AppEnvironment.shared`, so the first caller creates it:

- `App.init` creates it and injects it with `.environment(_:)`.
- `CarPlaySceneDelegate` reads `AppEnvironment.shared` on connect, because CarPlay can launch the app without a window scene.

It owns these services:

- Session and account.
- `LibraryStore` (P3-05 #45): shared, keyed by library ID, and owning no current library.
- `AppSettings` (P1-05 #28), which includes the last-used library per server and user.
- `PlaybackCoordinator` (P2-06a #52) and the `PlayerViewModel` that wraps it.
- Downloads.

It does **not** own a `Router` or any presentation state. Navigation and presentation are per window scene.

**CarPlay templates**

- CarPlay builds its own tree:
  - `CPTabBarTemplate` with at most 4 tabs, for example Continue, Library and Downloads.
  - `CPListTemplate`s up to a depth of 5.
  - `CPNowPlayingTemplate.shared`.
- CarPlay keeps its own current library. It starts from the `AppSettings` last-used library, and its library switch writes back to `AppSettings`.
- CarPlay starts playback through `PlaybackCoordinator`. Every window's mini player appears because each window observes the same `PlayerViewModel`.
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
| `WindowGroup(id:for:)`, `openWindow(id:value:)`, `SceneStorage`, `onOpenURL`, `userActivity` / `onContinueUserActivity`, `handlesExternalEvents` | ≤ iOS 16, macOS 13 | Routing and restoration |

**Minimum version per API**

- Every API marked **27.1** is above the 27.0 deployment target and is gated with `if #available(iOS 27.1, macOS 27.1, *)` or `@available(iOS 27.1, macOS 27.1, *)`.
- Every API that is unavailable on macOS is wrapped in `#if os(iOS)`.
- Everything else is available at 27.0.

## Consequences

**Positive**

- One root view tree works on every platform. Folding, unfolding, window resizing and Slide Over keep tab selection, per-tab paths and the player presentation.
- iPhone Duo vertical bars, Liquid Glass and Mac toolbars come from the system.
- Routing, deep links, Handoff and restoration share one `DeepLink → Router.open` path that can be unit tested.
- Navigation state is a plain `Codable` `[AppTab: [Route]]` in ABSAppModel, with no SwiftUI. Tests can assert exact paths after deep links, restoration, normalization and library or server switches.
- CarPlay stays decoupled and reuses services through `AppEnvironment`.
- Presentation state is per scene, so one window, or CarPlay, never presents the player in another window.

**Negative and risks**

- There is no three-column browse layout on iPad or Mac. Item detail replaces the list instead of sitting beside it.
  - Mitigations: "Open in New Window" and the inspector.
  - Revisit if users ask for a column layout. That would be a new ADR, and the detail column could not host `ArrangementView`.
- The Mac mini player is custom (`safeAreaInset`), and its placement differs from iOS.
- Sidebar-only section tabs need `Router.normalize(isCompact:)` and tests.
- Two code paths exist below 27.1 for arrangement and toolbar axis behavior. They should be removed when the minimum OS moves to 27.1.
- Only `Route` can be pushed onto a tab's stack. A future destination type must become a `Route` case, which is intended.
- `Router` needs a `subscript(path:)` to bind each `NavigationStack`.
- If the legacy app is still installed, it may receive `audiobookshelf://` links.

**Follow-ups**

- **P3-04 #44**:
  - Add `NSUserActivityTypes` (`org.davidjensenius.Audiobookshelf.item`) to the app's `Info.plist` (done in P3-04d #179).
  - Implement `AppTab`, `Route`, `Router` and `DeepLink` in `ABSAppModel/Navigation/`, including the play-link confirmation rule.
  - Note the legacy-app scheme collision in the onboarding and release notes (the release notes have it in `docs/release.md`).
- **Handoff account identity** (#219): the payload names the account (#443), the item and episode screens publish it (#504), and the scene resolves it before opening. Publishing from the player remains. See "Handoff".
- **P5-07 #84**: `DuoArrangement` in ABSUI.
- The player UI (P2-09 #56), iPad (P5-06 #83), Mac (P5-05 #82) and CarPlay (P5-02 #79, P5-03 #80) issues follow the placements above.

## Validation

**Verified for this ADR**

- **SDK check.** Every API in the table was looked up in the Xcode 27.2 `iPhoneOS27.2.sdk` and `MacOSX27.2.sdk` swiftinterfaces, with its `@available` attributes.
- **Throwaway spike** (`/tmp/abs-spike-nav`, deleted afterwards).
  - The spike contained the proposed `RootView`: `TabView`, `TabSection`, search role, sidebar header, bottom accessory, `fullScreenCover`, inspector, `focusedSceneValue`, `onOpenURL`, `onContinueUserActivity` and `SceneStorage`.
  - It also contained `Router`, `DeepLink`, the `DuoArrangement` wrapper, a fold-aware grid and 27.1 toolbar modifiers.
  - The app scenes were included as well: `WindowGroup(for: Route.self)`, `Window`, `Settings`, `commands` with `@FocusedValue(Router.self)`, and `restorationBehavior`.
- **Router spike.** A follow-up spike also typechecked, with no errors, for both targets below.
  - Its `Router` imported only Foundation and Observation, and held `[AppTab: [Route]]` paths and per-scene presentation flags.
  - `NavigationStack(path: $router[path: tab])`, `fullScreenCover` and `inspector` bound to the router's flags.
  - `@SceneStorage` held a JSON `Data` snapshot.
  - The first attempt bound `$router.paths[tab, default: []]`, which fails with "subscript index of type '() -> [Route]' in a key path must be Hashable". That is why `Router` has a subscript.
- **Typecheck results.** The spike typechecked with no errors in Swift 6 mode:
  - `xcrun --sdk iphonesimulator swiftc -typecheck -parse-as-library -swift-version 6 -target arm64-apple-ios27.0-simulator`;
  - `xcrun --sdk macosx swiftc -typecheck -parse-as-library -swift-version 6 -target arm64-apple-macos27.0`.
- **`ArrangementView` without a gate fails.** Using it without `if #available` at a 27.0 target fails with "'ArrangementView' is only available in iOS 27.1 or newer". This confirms the gating requirement.
- **Gated toolbar items typecheck.** `if #available(iOS 27.1, *)` inside a `@ToolbarContentBuilder` around `.axisBehavior(.verticalPreferred)` typechecks at a 27.0 target.

**Runtime and device validation (performed in the implementing issues)**

None of this was run for this ADR. Each item is an acceptance criterion of the issue that implements it:

- **Performed in #44 (P3-04):**
  - `Router` and `DeepLink` tests in the ABSAppModel test target. They cover parsing, `oauth` being rejected, the play-link confirmation and resume-only rule, the snapshot JSON round trip, `normalize(isCompact:)`, path resets on library and server switches, and presentation flags staying per scene.
  - Sidebar-only section tabs (`.defaultVisibility(.hidden, for: .tabBar)`) behave as described when the window becomes compact.
  - The mini-player slot (`tabViewBottomAccessory`) works in tab-bar and sidebar modes.
  - These are checked on iPhone, iPad and Mac.
- **Performed in #56 (P2-09):** mini player and full-player presentation on iPhone, iPad and Mac, including the Mac Now Playing window.
- **Performed in #84 (P5-07):**
  - On the iPhone Duo simulator (Xcode 27.2), `splitArrangementAxis` is `nil` when only the primary pane shows.
  - `.split.axes(.horizontal)` shows primary-only in laptop pose, with controls below the `.division` region.
  - The player is checked in flat, book, laptop, tent and outer forms.
  - The 27.0 fallback works, on the assumption that iPhone Duo always runs 27.1 or later.
- **Performed in #85 (P5-08):** iPhone Duo vertical bars (including the bottom accessory on the outer display), `toolbarVerticalEdge` insets, and even, fold-aware grid columns.
- **Performed in #66 (P3-11):** the detail `ArrangementView` shows inline secondary content when not split.
- **Performed in #83 (P5-06) and #82 (P5-05):** multiple windows, menus and commands, and `supportsMultipleWindows` on iPad, iPhone Duo inner and Mac.
- **Performed in #79 and #80 (P5-02, P5-03):** CarPlay starts from, and writes back, the `AppSettings` last-used library.
- **Simulator caveats.** Black screenshots appear for minutes after boot. VoiceOver is unavailable on iPhone Duo in 27.2.

## References

- [Platform API research](../research/platform-apis.md), §1 (iPhone Duo), §1.9 (suggested adaptation) and §2 (CarPlay)
- [Legacy feature inventory](../research/legacy-feature-inventory.md)
- Legacy: `layouts/default.vue`, `components/app/Appbar.vue`, `components/app/SideDrawer.vue`, `components/home/BookshelfNavBar.vue`, `plugins/init.client.js` (`appUrlOpen`), `ios/App/App/Info.plist` (`CFBundleURLSchemes`)
- Xcode 27.2 SDK: `SwiftUI.swiftinterface` and `SwiftUICore.swiftinterface` (iPhoneOS27.2.sdk and MacOSX27.2.sdk)
- Apple: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Designing for iPhone Duo (HIG)](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview), [ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion), [toolbarVerticalEdge](https://developer.apple.com/documentation/swiftui/environmentvalues/toolbarverticaledge)
