# AGENTS.md

Instructions for coding agents (and humans) working in this repository.

## Project goal

Build a native SwiftUI client for self-hosted [Audiobookshelf](https://www.audiobookshelf.org)
servers that runs on iPhone, iPad, iPhone Duo (foldable), Mac, and CarPlay,
replacing the Nuxt/Capacitor app this repository was forked from. Track work on the
[roadmap board](https://github.com/users/djensenius/projects/15).

## Layout today

The new Swift app and package structure will be added in Phase 0; document it here
when it lands. Everything else is **legacy reference code** — read it to port
behavior, but it is not built:

| Path | What it is |
| --- | --- |
| `pages/`, `components/`, `layouts/` | Vue screens and components (UI behavior to port to SwiftUI) |
| `store/`, `plugins/`, `mixins/`, `utils/` | App state, server/API helpers, shared logic |
| `ios/App/` | Capacitor-era native Swift — the best reference for the player, downloads, and progress sync |
| `android/` | Android app — ignore |
| `strings/` | Translations for 42 locales — the source for localization |

Repository tooling lives in `scripts/`, `.github/workflows/`, and `mise.toml`.

## Toolchain

- Xcode 27.2 at `/Applications/Xcode.app`. Prefix Apple builds and tests with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, for example
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- [mise](https://mise.jdx.dev) pins tools and defines tasks. Run `mise install`
  once, then `mise run lint` (ShellCheck + actionlint) before pushing.

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
