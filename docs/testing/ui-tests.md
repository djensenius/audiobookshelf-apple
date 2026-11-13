# UI tests

`AudiobookshelfUITests` drives the app with XCUITest against a canned server, so no
Audiobookshelf server, network or account is needed. UI tests use XCTest rather than Swift
Testing, because `XCUIApplication` needs an XCTest UI test runner.

## Run them

```sh
mise run test:ui                                   # macOS, signed ad hoc as test:app is
ABS_UI_PLATFORM=ios mise run test:ui               # the iPhone Duo simulator (IOS_SIMULATOR_ID overrides)
mise run test:ui -- -only-testing:AudiobookshelfUITests/FixtureSmokeTests -jobs 2
```

`test:app` and `test:ios` skip `AudiobookshelfUITests`; `test:ui` runs only it. CI doesn't run
UI tests yet (#46).

On macOS, XCUITest needs Automation Mode. If a run stops with an authentication prompt or
"Automation Mode is disabled", check it with `automationmodetool` and enable it once with
`sudo automationmodetool enable-automationmode-without-authentication`.

## The fixture server

A Debug build launched with `-ABSFixtures` (`Audiobookshelf/Fixtures/FixtureServer.swift`):

- answers requests to `https://fixtures.audiobookshelf.invalid` with `FixtureURLProtocol`, which
  is added only to the session configurations the app's `AppEnvironment` is given (API clients,
  sign-in and the cover pipeline), never registered globally;
- keeps the store, Keychain and settings in memory, so every launch starts signed out and
  touches nothing a normal launch saved.
- caches covers in `AudiobookshelfFixtures/Covers` in the temporary directory, emptied on every
  fixture launch, instead of the app's cover cache, and loads them without waiting for the
  network monitor, so fixture covers neither evict real ones nor fail offline.

Type the fixture address on the connect screen and sign in with any username and password.

The replies are the `fixture-*` files in `Audiobookshelf/Fixtures/Resources/`: status, ping,
login and authorize, `/api/me`, the libraries, the library with its filter data, the
personalized shelves, one page of items, the expanded *Pride and Prejudice*
(`fixture-item-li_pride.json`) and one cover PNG for every item. A request without a fixture is
a 404, logged to the `api` category as `Fixture server: no fixture for <method> <path>`, so a
missing fixture shows up in Console or the test's log.

## Playback

*Pride and Prejudice* plays. Its `POST /api/items/li_pride/play` returns
`fixture-play-li_pride.json`, a direct-play session of one 60-second track in two chapters. Each
`/play` replaces the file's `fixture-session-id` with a new ID, as a real server opens a new
session; `GET /api/session/:id` returns the same session under the ID asked for, and every
session's `/sync` and `/close` answer `{}`. Other items have no session fixture, so their Play
fails with the 404 above.

AVPlayer loads tracks outside the app's URL sessions, so `FixtureURLProtocol` can't serve them.
Instead a fixture launch gives every playback scope a track URL override
(`PlaybackScope.Configuration.trackURLOverride`, set from `AppPlayback.fixtureTrackURL` in
`Audiobookshelf/AppEnvironment+Fixtures.swift`): `FixtureServer.trackURL(_:bundle:)` turns a
fixture session's `/public/session/:id/track/:index` into the bundled `fixture-silence.m4a`, a
minute of mono AAC silence (6 KB), and leaves every other URL alone. A normal launch, and every
Release build, has no override.

To regenerate the audio, write a silent WAV (for example with Python's `wave` module: mono,
8 kHz, 16-bit, 60 seconds of zeros) and convert it:

```sh
afconvert -f m4af -d aac -b 16000 -c 1 silence.wav Audiobookshelf/Fixtures/Resources/fixture-silence.m4a
```

If its length changes, change the session's `duration`, track and chapters to match.

The metadata is public-domain LibriVox material, matching `SampleLibrary` (library
`lib_sample`, the same item IDs and titles); narrators are "LibriVox Volunteers". To add an
endpoint, add a route in `FixtureServer.resource(method:path:)` and a `fixture-*` file; the file
names must be unique, because the synchronized folder copies resources flat into the app.

Release builds compile `FixtureServer` out (`#if DEBUG`) and leave the files out, the audio
included (`EXCLUDED_SOURCE_FILE_NAMES[config=Release]` is `fixture-*` on the app target).

## Writing a test

Find elements by accessibility identifier, never by visible text, so tests pass in any
language. The connect flow has `connect.address`, `connect.submit`, `connect.username`,
`connect.password` and `connect.signIn`; Home is `home.screen`. Add an identifier where a test
needs one; don't change visible strings for a test.

Not covered yet (#46): a CI job, HLS and podcast playback fixtures, screenshots (#109) and
accessibility audits (#106).
