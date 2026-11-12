# Changelog

All notable changes to the native Audiobookshelf app for iPhone, iPad and Mac are
recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Builds are referred to by their TestFlight build number, for example "1.0.0 (42)". The
topmost section with entries becomes TestFlight's "What to Test" notes
([docs/release.md](docs/release.md)). Before tagging a release, move the `Unreleased`
entries into a new version section with `mise run release:version` and the tag date.

## [Unreleased]

### Added

- A native SwiftUI app for iPhone, iPad and Mac, replacing the Capacitor app.
- Server connection and sign-in, including OpenID Connect, with several saved servers
  and accounts.
- Home shelves, the library grid and list with filters and sorting, search, series,
  authors, collections and playlists.
- Book, podcast and episode screens, with chapters, tracks, bookmarks and listening
  history.
- Streaming playback with Now Playing, playback speed, a sleep timer with shake to reset,
  and automatic advance to the next item.
- Progress sync with the server that survives going offline, and live updates from the
  server.
- Downloads for offline listening, with pause, resume, retry and cellular controls.
- Add to playlist from a book or episode.
- Listening stats, shareable Year in review cards, and a log viewer.
- Translations for the languages the previous app supported.

[Unreleased]: https://github.com/djensenius/audiobookshelf-apple/commits/main
