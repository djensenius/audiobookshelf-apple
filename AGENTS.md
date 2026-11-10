# AGENTS.md

Instructions for coding agents (and humans) working in this repository.

## Project goal

Build a native SwiftUI client for self-hosted [Audiobookshelf](https://www.audiobookshelf.org)
servers that runs on iPhone, iPad, iPhone Duo (foldable), Mac, and CarPlay,
replacing the Nuxt/Capacitor app this repository was forked from. Track work on the
[roadmap board](https://github.com/users/djensenius/projects/15).

## Layout today

### Native app

| Path | What it is |
| --- | --- |
| `Audiobookshelf.xcodeproj/project.xcproj` | Xcode 27.2 JSON project: app target `Audiobookshelf` (iOS, iPadOS, native macOS; no Catalyst) and test target `AudiobookshelfTests` |
| `Audiobookshelf/` | App sources (synchronized folder), `Info.plist` fragment (ATS, background audio, CarPlay scene), entitlements (`Audiobookshelf.entitlements` macOS, `Audiobookshelf-iOS.entitlements` iOS, `Audiobookshelf-AdHoc.entitlements` for ad hoc `test:app`) |
| `AudiobookshelfTests/` | App tests (Swift Testing), hosted in the app |
| `Localization/native/` | Native-only string keys merged into the String Catalog ([docs/localization.md](docs/localization.md)) |
| `Packages/AudiobookshelfKit/` | Local Swift package with all feature code; one `AudiobookshelfKit` library product exposes every module |

`AudiobookshelfKit` modules (all are declared in `Package.swift` already; add source
files, don't add targets without need):

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `ABSCore` | Models and shared utilities | — |
| `ABSAPI` | HTTP client, authentication, endpoints | ABSCore |
| `ABSRealtime` | Socket.IO real-time updates | ABSCore, ABSAPI |
| `ABSData` | SwiftData persistence | ABSCore |
| `ABSPlayback` | Playback and progress sync | ABSCore, ABSAPI, ABSData |
| `ABSDownloads` | Offline downloads | ABSCore, ABSAPI, ABSData |
| `ABSUI` | Shared SwiftUI components and design system | ABSCore |
| `ABSAppModel` | Account and library state, routing, feature view models, realtime bridge | ABSCore, ABSAPI, ABSRealtime, ABSData, ABSPlayback, ABSDownloads |

`ABSUI` never imports `ABSAppModel`, and `ABSAppModel` never imports `ABSUI`. See
[the package README](Packages/AudiobookshelfKit/README.md).

Each module has a `<Module>Tests` target. Package tests run with `swift test`
(`mise run test:kit`); they cannot be added to the app scheme.

Read [docs/architecture.md](docs/architecture.md) for the allowed module
dependencies, the `Features/<Feature>/` layout, `AppEnvironment`, concurrency rules,
and the testing guide. Significant decisions are recorded as ADRs in
[docs/adr/](docs/adr/README.md).

Bundle IDs: `org.davidjensenius.Audiobookshelf` and
`org.davidjensenius.AudiobookshelfTests`. Team `9JALHNGRBQ`, automatic signing.
App Group `group.org.davidjensenius.Audiobookshelf`; keychain access group
`$(AppIdentifierPrefix)org.davidjensenius.Audiobookshelf`. See
[ADR 0002](docs/adr/0002-identity-and-no-migration.md).

CarPlay: the scene and `CarPlaySceneDelegate` exist, but the
`com.apple.developer.carplay-audio` entitlement is not added yet — it requires Apple
approval. Once granted, add it to `Audiobookshelf/Audiobookshelf-iOS.entitlements`
(used for the `iphoneos` and `iphonesimulator` SDKs), not to the macOS
`Audiobookshelf/Audiobookshelf.entitlements`.

### Legacy reference

Everything else is **legacy reference code** — read it to port behavior, but it is
not built:

| Path | What it is |
| --- | --- |
| `pages/`, `components/`, `layouts/` | Vue screens and components (UI behavior to port to SwiftUI) |
| `store/`, `plugins/`, `mixins/`, `utils/` | App state, server/API helpers, shared logic |
| `ios/App/` | Capacitor-era native Swift — the best reference for the player, downloads, and progress sync |
| `android/` | Android app — ignore |
| `strings/` | Translations for 42 locales — the source for localization |

Repository tooling lives in `scripts/`, `Tools/` (Swift tool packages, e.g. the strings
importer), `.github/workflows/`, and `mise.toml`.

## Toolchain

- Xcode 27.2 at `/Applications/Xcode.app`. Prefix Apple builds and tests with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, for example
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- [mise](https://mise.jdx.dev) pins tools and defines tasks. Run `mise install`
  once. mise tasks set `DEVELOPER_DIR` to Xcode.app unless it is already set.

| Command | What it does |
| --- | --- |
| `mise run lint` | ShellCheck, actionlint, and `swift format lint --strict` (`lint:repo` skips Swift) |
| `mise run format` | `swift format` Swift sources in place |
| `mise run build:ios` / `build:macos` | Build the app (unsigned) into `.build/DerivedData` |
| `mise run test` | Package tests (`test:kit`), tool tests (`test:tools`), and macOS app tests (`test:app`, signed ad hoc) |
| `mise run test:tools` | Tests for repository tools in `Tools/` (the strings importer) |
| `mise run strings` / `strings:check` | Generate or verify ABSUI's `Localizable.xcstrings` from `strings/*.json` and `Localization/native/`; see [docs/localization.md](docs/localization.md) |
| `mise run test:ios` | App tests on an iPhone Duo simulator (override with `IOS_SIMULATOR_ID`; local only, not in CI) |
| `mise run xcproj:check` / `xcproj:format` | Check or rewrite `project.xcproj` in canonical form |

Run `mise run lint`, `mise run xcproj:check`, and `mise run test` before pushing.

## Xcode project rules

- The project uses the JSON format. Never create `project.pbxproj` — Xcode refuses
  to open a project with both files.
- Never use `agvtool`; it breaks JSON projects. Edit `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `project.xcproj` directly.
- Keep `project.xcproj` canonical (`mise run xcproj:format`, which builds Apple's
  `xcprojformatter` at a pinned commit). CI fails otherwise.
- Target IDs are fixed strings (`AB0000000000000000000001` app,
  `…0002` tests) referenced by the shared scheme; don't change them.
- New app files go in the synchronized `Audiobookshelf/` folder; no project edit is
  needed.

## Conventions

- Swift 6 language mode with complete strict concurrency checking.
- SwiftUI with Observation (`@Observable`), SwiftData for persistence, and
  `URLSession` with async/await for networking.
- Swift Testing (`import Testing`) for tests.
- Format with `swift format`.
- Prefer built-in Apple frameworks. Any new Swift Package Manager dependency must be
  justified in the PR description.
- Do not add CocoaPods, Carthage, Capacitor, or Fastlane. Releases go through
  Xcode Cloud.

## Pull requests

- One issue per PR, at most 20 files and 2000 hand-written lines (generated files
  and deletions excluded).
- Fill in [the PR template](.github/pull_request_template.md), including the exact
  commands you ran and their results.
- Merge commits only: no squash or rebase merges, and never rewrite published
  history.
- Copilot review runs on every push; address its comments.
- CI must be green on the exact head SHA before merging.

## Legacy code and upstream

- Never modify legacy reference code (the paths above) except in the dedicated
  legacy-removal phase.
- Upstream [advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app)
  is still active. Port its changes by following
  [docs/upstream-sync.md](docs/upstream-sync.md).
