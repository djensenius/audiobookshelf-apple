# AudiobookshelfKit

Local Swift package with the app's feature code. The app links the single
`AudiobookshelfKit` library product and imports the modules it needs.

## Modules and dependency direction

Dependencies point down only; there are no cycles.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `ABSCore` | Models and shared utilities | — |
| `ABSAPI` | HTTP client, authentication, endpoints | ABSCore |
| `ABSRealtime` | Socket.IO real-time updates | ABSCore, ABSAPI |
| `ABSData` | SwiftData persistence | ABSCore |
| `ABSPlayback` | Playback and progress sync | ABSCore, ABSAPI, ABSData |
| `ABSDownloads` | Offline downloads | ABSCore, ABSAPI, ABSData |
| `ABSUI` | Shared SwiftUI components, design system, localized strings | ABSCore |
| `ABSAppModel` | Account and library state, routing, feature view models, realtime bridge | ABSCore, ABSAPI, ABSRealtime, ABSData, ABSPlayback, ABSDownloads |

- `ABSUI` never imports `ABSAppModel`. Shared components take plain values and
  closures.
- `ABSAppModel` never imports `ABSUI` and defines no views.
- `ABSPlayback`, `ABSDownloads`, and `ABSRealtime` don't import each other;
  `ABSAppModel` coordinates them.

See [docs/architecture.md](../../docs/architecture.md) for the full rules.

## Resources

- `ABSUI` processes `Sources/ABSUI/Resources/` (the string catalog arrives with the localization issue). The package's
  default localization is `en`.
- `ABSCoreTests`, `ABSAPITests`, and `ABSPlaybackTests` copy their `Fixtures/`
  folder; load files with
  `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures")`.

## Tests

Run `mise run test:kit` from the repository root.
