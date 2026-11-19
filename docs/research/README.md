# Research notes

Point-in-time research (November 2026, Xcode 27.2 / iOS and macOS 27.2 SDKs) gathered while planning the native SwiftUI conversion. Issues in the conversion project link to sections here.

| File | Covers |
| --- | --- |
| [`platform-apis.md`](platform-apis.md) | iPhone Duo layout APIs, CarPlay audio, Now Playing, AVFoundation, App Intents, widgets, SwiftData, background `URLSession`, OIDC with `ASWebAuthenticationSession`, String Catalogs, zip/CBZ, Socket.IO over `URLSessionWebSocketTask` |
| [`xcode-project-and-ci.md`](xcode-project-and-ci.md) | Historical Xcode 27.2 JSON project format (`project.xcproj`) and CI research; current release path is in [docs/release.md](../release.md) |
| [`legacy-api-inventory.md`](legacy-api-inventory.md) | Audiobookshelf server endpoints the legacy app calls |
| [`legacy-feature-inventory.md`](legacy-feature-inventory.md) | Pages, settings and workflows the native app must match |

These notes are not kept up to date. When code, Architecture Decision Records or Apple documentation disagree with them, those win.
