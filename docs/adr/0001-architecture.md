# 0001. Architecture: modules, app layout, and concurrency

- Status: Accepted
- Date: 2026-11-09
- Issue: [#21](https://github.com/djensenius/audiobookshelf-apple/issues/21) (P0-05)

## Context

The app is being rebuilt from scratch as a native SwiftUI client for iPhone, iPad,
iPhone Duo, Mac, and CarPlay, replacing the Nuxt/Capacitor app. Much of the work
runs in parallel, often by coding agents in separate worktrees, with each pull
request capped at 20 files and 2,000 hand-written lines. Without a shared
structure, parallel PRs would invent incompatible layers and conflict on the
project file.

Constraints:

- One multiplatform app target (iOS/iPadOS and native macOS, not Catalyst) in the
  Xcode 27.2 JSON project format. Project-file edits are expensive to review and
  conflict-prone, so app sources use a synchronized folder.
- Swift 6 language mode with complete strict concurrency checking.
- The app can launch with only the CarPlay scene connected, so playback and
  account state cannot belong to a window scene.
- `AVAudioSession` exists on iOS only; Now Playing, downloads, and SwiftData must
  work on both iOS and macOS.
- The legacy app spreads state across Vuex stores (`store/`), Capacitor plugins
  (`plugins/`), and a singleton-heavy native layer (`ios/App/Shared/`). We port its
  behaviour, not its structure.

## Decision drivers

1. Logic is testable with `swift test` on macOS, without a simulator or the app
   host.
2. Parallel PRs touch disjoint files, and rarely `Package.swift` or
   `project.xcproj`.
3. Compiler-checked boundaries: module imports and Swift 6 isolation catch layering
   and data-race mistakes before review does.
4. One playback and account state shared by window and CarPlay scenes.
5. Built-in Apple frameworks and tools only; no project generators.

## Options considered

### Option 1: Everything in the app target

All code in `Audiobookshelf/`, organised by folder.

- Pros:
  - Simplest setup; no package or access-control boilerplate.
- Cons:
  - Tests need the app host and `xcodebuild`, which is slow and needs a full app
    build.
  - No enforced boundaries; any file can reach any other.

### Option 2: One local package with a few layered modules (chosen)

`Packages/AudiobookshelfKit` declares `ABSCore`, `ABSAPI`, `ABSRealtime`,
`ABSData`, `ABSPlayback`, `ABSDownloads`, `ABSUI`, and later `ABSAppModel`, all up
front, behind one `AudiobookshelfKit` product. The app target keeps only views,
scenes, CarPlay, and the composition root.

- Pros:
  - Fast `swift test` for nearly all logic.
  - Declared dependencies make layering visible and reviewable in one file.
  - Declaring every module up front means feature PRs add source files only.
  - `public` access marks each module's API.
- Cons:
  - Public API boilerplate across module boundaries.
  - Package tests can't run in the app scheme; CI runs `test:kit` and `test:app`
    separately.

### Option 3: Many fine-grained packages, or a generated project (Tuist, XcodeGen)

One package or module per feature, or a project generated from a manifest.

- Pros:
  - Strongest isolation and incremental builds.
- Cons:
  - Many manifests and products to keep in sync; every feature PR edits build
    configuration.
  - Generators add a third-party tool and fight the hand-maintained JSON project.

## Decision

Use Option 2. The full rules are in [architecture.md](../architecture.md); in
summary:

- **Modules** depend only downwards: `ABSCore` ← `ABSAPI` ← `ABSRealtime`;
  `ABSCore` ← `ABSData`; `ABSPlayback` and `ABSDownloads` use Core, API, and Data;
  `ABSUI` uses Core only. `ABSAppModel` (P0-02, the only planned target addition)
  sits on top of everything except `ABSUI`, and holds account and library state,
  routing, feature view models, and the realtime bridge.
- **App target:** SwiftUI views in `Audiobookshelf/Features/<Feature>/`, CarPlay in
  `Audiobookshelf/CarPlay/`, and `AppEnvironment`.
- **`AppEnvironment`** is a `@MainActor` composition root created once per process,
  outside any scene, and shared by the window and CarPlay scenes.
- **Concurrency:** view models are `@MainActor @Observable`; services are actors
  (or `@MainActor` when an Apple framework requires it); only `Sendable` DTOs cross
  actors; `@Model` objects never cross actors; `AVAudioSession` code is wrapped in
  `#if os(iOS)`.
- **Testing:** Swift Testing, hand-written fakes, `URLProtocol` stubs, JSON fixtures,
  in-memory SwiftData, and injected clocks.

## Consequences

- Adding a module, or a dependency edge not in the architecture table, needs a new
  ADR.
- Views stay thin; behaviour worth testing goes in `ABSAppModel` or a lower module.
- CarPlay and window code reach the same objects, so CarPlay-only launches work
  once `AppEnvironment` owns the services.
- Topic decisions (identity, SwiftData, navigation, images, Now Playing, streaming,
  readers) build on this ADR in [0002–0008](README.md#index).
- Contributors must mark cross-module API `public` and keep DTOs `Sendable`.

## Validation

- `Package.swift` declares each module's dependencies; SwiftPM only links declared
  dependencies, and reviewers check that the manifest matches the table in
  [architecture.md](../architecture.md).
- Swift 6 strict concurrency turns isolation mistakes (such as passing a `@Model`
  across actors) into compile errors in `mise run test:kit` and the app builds.
- CI runs `lint:swift`, `xcproj:check`, `test:kit`, `build:ios`, and `test:app` on
  every PR.

## References

- [docs/architecture.md](../architecture.md)
- [AGENTS.md](../../AGENTS.md)
- [Platform API research](../research/platform-apis.md), sections 3 (playback), 4
  (SwiftData and background URLSession), and 9 (cross-cutting recommendations)
- [Xcode project and CI research](../research/xcode-project-and-ci.md)
- Legacy: `ios/App/Shared/`, `plugins/`, `store/`
