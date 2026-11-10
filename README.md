# Audiobookshelf for Apple platforms

A native SwiftUI client for a self-hosted [Audiobookshelf](https://www.audiobookshelf.org)
server, targeting iPhone, iPad, iPhone Duo, Mac, and CarPlay.

> [!WARNING]
> **Status: early conversion — not yet usable.** The native app is being built
> from scratch. Follow progress on the
> [roadmap board](https://github.com/users/djensenius/projects/15).

## Technical direction

- SwiftUI app in Swift 6, with SwiftData for local storage, `URLSession` for
  networking, AVFoundation for playback, and the CarPlay framework.
- Swift Package Manager only — no CocoaPods or Capacitor.
- Xcode 27.2 with the JSON project format.
- [mise](https://mise.jdx.dev) for tools and tasks (`mise run lint`).
- Xcode Cloud for TestFlight builds.

## Relationship to upstream

This repository started from
[advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app) and keeps
its full history. The legacy Nuxt, Capacitor, and Android sources remain in the
tree only as a porting reference and will be removed in a later phase. New
upstream changes are tracked and ported as described in
[docs/upstream-sync.md](docs/upstream-sync.md).

Contributors and coding agents should read [AGENTS.md](AGENTS.md).

## License

[GPL-3.0](LICENSE). Built on the work of the Audiobookshelf authors and
contributors — thank you to [advplyr](https://github.com/advplyr) and everyone who
has contributed to
[audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app/graphs/contributors)
and [Audiobookshelf](https://github.com/advplyr/audiobookshelf).
