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

`test:app` and `test:ios` skip `AudiobookshelfUITests`; `test:ui` runs only it, or only the tests
you pick with `-only-testing`.

On macOS, XCUITest needs Automation Mode. If a run stops with an authentication prompt or
"Automation Mode is disabled", check it with `automationmodetool` and enable it once with
`sudo automationmodetool enable-automationmode-without-authentication`.

## In CI

The CI workflow's *UI tests* job runs beside *Lint, build, and test*, so its cold builds don't
lengthen that job. It creates its own iPhone Duo simulator (`abs-ui-<run>-<attempt>`), boots it
and waits for the boot to finish (`xcrun simctl bootstatus <udid> -b`, as a cold simulator's
first launch can time out), runs `scripts/ui-test-ci.sh` (below) on it with
`ABS_UI_PLATFORM=ios` and `IOS_SIMULATOR_ID`, and always deletes it.

If those pass, it runs one test on a regular-width iPad simulator too
(`abs-ui-ipad-<run>-<attempt>`, an iPad Pro 13-inch (M5), also always deleted):
`MiniPlayerTests/testLongPressAtAccessibilitySizeShowsNoMenu`, with the same script and
`ABS_UI_ACTION=test-without-building`, reusing the iPhone build. The Duo is compact, so it never
reaches `open`'s sidebar fallback (#693), which that test needs on an iPad at AX sizes. The
iPad accessibility audits fail for other reasons (#698), so they don't run there. The iPhone Duo
is shut down before the iPad is created, so the two don't normally run at once. The step has its
own 35-minute limit: the test takes about 5 minutes locally, but the CI runner can take over 12
minutes to start the test runner on the cold iPad simulator, and the first passing run took 21
(#703). A stall there fails the step and uploads its results instead of the job's limit
cancelling the run.

It then runs `mise run test:ui` on macOS only if `automationmodetool` reports Automation Mode
enabled on the runner. Otherwise the step passes with a *macOS UI tests skipped* warning
annotation on the run: an administrator must enable Automation Mode on the runner (the command
above) before CI covers macOS.

`scripts/ui-test-ci.sh` runs `mise run test:ui` with these flags, which local runs of `test:ui`
don't add:

- `-retry-tests-on-failure -test-iterations 2`: a failed test runs once more in the same test
  runner, so a launch timeout on a busy runner is retried without another run.
- `-test-timeouts-enabled YES`, with `-default-test-execution-time-allowance` and
  `-maximum-test-execution-time-allowance` both 600 seconds: a test still running after 10
  minutes fails, so a hang ends in time. On #660 an accessibility audit hung for 25 minutes and
  the job ran out of time (#661). The slowest passing test, an audit, has taken up to 371
  seconds on a slow runner (it ran first and paid for the cold app launch); in most runs the
  slowest takes under 250.

XCTest stops a timed-out test by ending the test runner, so the runner's retry can't repeat it:
the run restarts the runner, moves on, and the test fails. `-test-repetition-relaunch-enabled YES`
would retry it in a new runner, but it also ran the whole suite a second time after one flaky
failure, and the job ran out of time (#666). Instead, if the first run fails, the script reads
its result bundle (`xcrun xcresulttool get test-results tests`) and the tests it selected
(`-enumerate-tests`). If every selected test has a result, nothing failed outside a test and one
to three tests failed, it runs only those once more, without building
(`ABS_UI_ACTION=test-without-building`), with the same 10-minute limit. That run decides: the
step passes only if each of those tests ran and passed, and it then adds a *UI tests passed when
run again* warning annotation naming them. A test is run again only if its result is *Failed*
(it failed twice, ran out of time or crashed); one that passed on the runner's retry, was
skipped or is an expected failure isn't. Anything else (a build error, a crash outside a test,
an `xcodebuild` stopped by a signal, tests without a result, more than three failures, results
the script can't read) fails the step with the first run's exit status, without another run.

Recent passing runs took 36 to 58 minutes (median 47). A flaky test costs only its retry in the
runner. A hang adds the 10 minutes and about 3 more to restart the runner, list the tests and
run it again: the slowest run seen with a hang would end by minute 71 or so. The iPad
simulator and its step (up to 35 minutes, above) come after that, so the job's limit is 115
minutes. A second hang in the iPhone run may not fit; the job then times out and fails rather
than passing.

If the step fails, the job uploads `.build/ui-tests/` (the result bundles and lists of tests) as
the `ui-tests-iphone-duo-attempt-<attempt>` artifact, kept for 7 days.

To try it locally, pass a selection after the script's name; the result bundles and lists of
tests are left in `.build/ui-tests/`. `mise run test:ui:runner` (part of `mise run lint:repo`)
checks the script and `scripts/ui-test-results.py` with fake `mise` and `xcrun` commands, so it
needs no Xcode or simulator.

```sh
ABS_UI_PLATFORM=ios scripts/ui-test-ci.sh -only-testing:AudiobookshelfUITests/FixtureSmokeTests
```

## The fixture server

A Debug build launched with `-ABSFixtures` (`Audiobookshelf/Fixtures/FixtureServer.swift`):

- answers requests to `https://fixtures.audiobookshelf.invalid` with `FixtureURLProtocol`, which
  is added only to the session configurations the app's `AppEnvironment` is given (API clients,
  sign-in and the cover pipeline), never registered globally;
- keeps the store, Keychain and settings in memory, so every launch starts signed out and
  touches nothing a normal launch saved;
- caches covers in `AudiobookshelfFixtures/Covers` in the temporary directory, emptied on every
  fixture launch, instead of the app's cover cache, and loads them without waiting for the
  network monitor, so fixture covers neither evict real ones nor fail offline;
- keeps downloads in `AudiobookshelfFixtures/Downloads` in the temporary directory, emptied on
  every fixture launch, and sends every part of a transfer (the redirect check, the download
  session and the custom-header session) through `FixtureURLProtocol`, so the Downloads tab
  starts empty (`downloads.empty`), never sees a real download and never reaches the network.
  A track's download, `GET /api/items/:id/file/:ino/download`, answers with the bundled
  `fixture-silence.m4a` (`audio/mp4`, with its `Content-Length`), so *Pride and Prejudice*,
  whose one track is `ino` 11, downloads. Its Download button is `item.download` until the book
  is downloaded and `item.downloaded` after.

Type the fixture address on the connect screen and sign in with any username and password.

Add `-ABSTheme <theme>` (`system`, `light`, `dark` or `black`, `AppTheme`'s raw values) to set
the fixture launch's theme setting, as the dark accessibility audits do (`FixtureTheme`). A newly
created simulator ignores `XCUIDevice.shared.appearance` and `simctl ui appearance` until it's
rebooted, so this is how a test sees dark mode. Only fixture launches read it.

Add `-ABSStallDownloads` to keep a track's download under way: its reply sends the headers and
half of the audio, then nothing more, so the download queue and the tab roots' queue indicator
(`downloads.queueIndicator`) stay up. It holds for about a minute: the download session's
request timeout (a minute without data, by default) can then end the transfer, so check the
indicator soon after starting the download.

The replies are the `fixture-*` files in `Audiobookshelf/Fixtures/Resources/`: status, ping,
login and authorize, `/api/me`, the libraries, the library with its filter data, the
personalized shelves, one page of items, one page of series (*Barsoom*, with its three books),
*Barsoom*'s detail (`GET /api/series/ser_barsoom`, `fixture-series-ser_barsoom.json`) and its books
(`fixture-items-series-ser_barsoom.json`), the expanded *Pride and Prejudice*
(`fixture-item-li_pride.json`, with one audio file and track) and a cover for every item. A request without a fixture is
a 404, logged to the `api` category as `Fixture server: no fixture for <method> <path>` (with
`?<query>` after the path when the request has one), so a
missing fixture shows up in Console or the test's log.

Routes match on the path, except the items list: with a series filter
(`filter=series.<id>`, the ID Base64-encoded and percent-encoded as `LibraryFilter.encode` sends it)
it answers with `fixture-items-series-<id>.json`, the series' books in sequence order with the
`series` context a real server adds, and any other query, including the Library's *No series*
filter (`LibraryFilter.noSeries`), gets the whole page. So opening *Barsoom*
from the Series grid or Home's *Recent Series* shelf shows *A Princess of Mars*, *The Gods of Mars*
and *The Warlord of Mars*; any other series, or a filter that doesn't decode, is a 404.

### Fixture covers

`GET /api/items/:id/cover` returns the item's own `fixture-cover-<id>.png` when the bundle has
one, and the shared 8 × 8 placeholder `fixture-cover.png` otherwise. *A Book Without a Cover*
(`li_nocover`) has no `coverPath`, so the app never asks for its cover and shows its no-cover
placeholder. The per-item covers are original typographic designs (title, author and a flat
geometric motif, 600 × 600, about 25–45 KB each) drawn by `scripts/fixture-covers.swift` with
the system fonts, so the repository holds only the PNGs. To change or add one, edit the list in
the script and run:

```sh
mise run fixtures:covers
```

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
endpoint, add a route in `FixtureServer.resource(method:path:query:bundle:)` and a `fixture-*` file; the file
names must be unique, because the synchronized folder copies resources flat into the app.

Release builds compile `FixtureServer` out (`#if DEBUG`) and leave the files out, the audio
included (`EXCLUDED_SOURCE_FILE_NAMES[config=Release]` is `fixture-*` on the app target).

## Writing a test

Find elements by accessibility identifier, never by visible text, so tests pass in any
language. The connect flow has `connect.address`, `connect.submit`, `connect.username`,
`connect.password` and `connect.signIn`; Home is `home.screen`. Add an identifier where a test
needs one; don't change visible strings for a test.

`FixtureSmokeTests` signs in and waits for Home's shelves to load (the *Continue Listening*
card `item.li_frankenstein`, as `home.screen` is there while they load or after they fail;
`testConnectsAndSignsIn`), then opens the Library tab
(`tab.library`; every tab is `tab.<AppTab raw value>`), checks `library.screen`, opens
*Pride and Prejudice*'s card (`item.li_pride`; Home and Library cards and rows are `item.<item ID>`) and
checks the item screen, `item.detail`, and its loaded title, `item.title`
(`testOpensLibraryItem`). Each test launches the app afresh, so a failure names the step. The
journey lives in `FixtureJourney.swift` (`signIn(launchArguments:screenshotPrefix:)` and
`openLibraryItem(in:screenshotPrefix:)`), so other test classes reuse it.

`FixtureScreens.swift` opens the screens tests need from the signed-in app:
`open(_ screen: FixtureScreen, in: app)` opens Home, Library, Item detail (*Pride and
Prejudice*), Player, Settings or Downloads from wherever the app is, waits for the screen's
loaded content and returns its element (`FixtureScreen.identifier`): `home.screen`,
`library.screen`, `item.detail`, `player.screen`, `settings.screen` or `downloads.screen`
(loaded: its empty state, `downloads.empty`, or its list; on iOS the list takes the screen's
identifier, so `downloads.screen` is then the collection view itself). Tabs keep their
navigation stacks, so `open` goes back (`BackButton`) to the tab's root (`home.screen`,
`library.screen`, `downloads.screen`, `account.screen`) before leaving it and after selecting
a tab; an open Settings screen is reused.
On iOS it also opens Missing item (*Emma*, which has no item fixture: `item.detail` with its
error state's Retry, `state.retry`), Bookmarks (the player's `player.bookmarks`, or the entry
with its symbol in a vertical bar's overflow menu; `bookmarks.create`, with the sheet dragged
to its large detent and closed with `player.sheet.done`) and Series (Barsoom, `series.ser_barsoom`,
from the Library's section menu or sidebar; `series.continue`). The dark audits walk these
(`FixtureScreen.accentButtonScreens`, #645).
The player plays *Pride and Prejudice* (`item.play`), opens from the mini player
(`player.mini`) and is paused; another screen minimizes it first (`player.minimize`). Its
play/pause button is `player.pause` while playback is requested and `player.play` otherwise,
in any language, so the helper presses it only while it's `player.pause` and never restarts
playback that has already stopped. Settings is the Account tab's `account.settings` row on iOS and ⌘, on a
Mac. The tab bar minimizes as the content scrolls (`tabBarMinimizeBehavior`); `open` expands
it. At accessibility text sizes a regular-width iPad's top tab bar pages and hides Account
behind its Next Page button, so if pressing a tab doesn't select it, `open` chooses it from the
sidebar: it shows the sidebar (`ToggleSideBar`), presses the tab's sidebar cell, and hides the
sidebar again (`ToggleSidebar`). It scrolls Account by swiping `account.screen`, not the first
collection view, which can be the sidebar. The item's metadata is `item.metadata`.

`TabBarTests` checks the compact tab bar (#617): Home, Library, Downloads, Account and Search,
with no More tab and no library section. It also chooses Series, then Library, from the
Library root's section menu (`library.sectionPicker`) and checks the root (`series.screen`,
`library.screen`). A menu's entries have no identifiers, so it finds them by symbol
(`AppTab.systemImage`). Menus drop those symbols at accessibility text sizes, so the test
runs at the default size. On the iPhone Duo's outer display the menu is in the vertical bar's
overflow menu (`BottomOverflowBarButtonItem`), titled with the Library tab's title. A
regular-width iPad and a Mac show the sidebar, so the tests skip there.

`TabBarTests.testSeriesSectionOpensBarsoom` follows the series journey (#639) the same way:
Library, then Series from the section menu, then the *Barsoom* card (`series.ser_barsoom`, a
series card's identifier is `series.<id>`). It waits for the series' three books
(`item.li_barsoom_1` to `_3`, served by `fixture-items-series-ser_barsoom.json`), checks each
card's label starts with its title, and checks the cards are in sequence order: *A Princess of
Mars*, *The Gods of Mars*, *The Warlord of Mars*.

`DownloadQueueIndicatorTests` starts a download of *Pride and Prejudice* with
`-ABSStallDownloads`, then checks the queue indicator (`downloads.queueIndicator`) is in the bar
of the Home and Library roots (#685), not their overflow menu, which isn't in the hierarchy
until it opens. It checks the indicator's label isn't its count and its value gives the count
and progress (#686), that it opens the queue (`downloads.list`), and that the Downloads root's
bar doesn't have it:

```sh
ABS_UI_PLATFORM=ios mise run test:ui -- -only-testing:AudiobookshelfUITests/DownloadQueueIndicatorTests -jobs 2
```

`AccessibilityAuditTests` audits each of those screens at the default text size and at AX5;
see docs/accessibility.md, "Automated audits". Locally the default size takes about 80 seconds on
the simulator and AX5 about 100; on CI's runners each audit has taken 110 to 371 seconds.

What the audits find depends on the screen's size, so they're verified on two simulators: the
iPhone Duo, which CI runs, and an iPhone 17 (iOS 27.2), a normal-width iPhone, which CI
doesn't, to keep the job's time down. Run them on an iPhone 17 too when changing a filter, the
tab bar or a screen they open. To run them on another device, create a simulator, boot it and
pass its ID:

```sh
xcrun simctl create abs-audits com.apple.CoreSimulator.SimDeviceType.iPhone-17  # prints <udid>
xcrun simctl boot <udid> && xcrun simctl bootstatus <udid> -b
ABS_UI_PLATFORM=ios IOS_SIMULATOR_ID=<udid> mise run test:ui -- -only-testing:AudiobookshelfUITests/AccessibilityAuditTests -jobs 2
xcrun simctl delete <udid>
```

## Localized runs and screenshots

`LocalizedSmokeTests` runs the same journey with launch arguments for another language:

| Test | Launch arguments | Screenshot prefix |
| --- | --- | --- |
| `testArabic` | `-AppleLanguages (ar) -AppleLocale ar` | `ar` |
| `testGerman` | `-AppleLanguages (de) -AppleLocale de_DE` | `de` |
| `testPseudoLanguage` | `-NSDoubleLocalizedStrings YES -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES` | `pseudo` |

Arabic is a real right-to-left language and German a long one. The pseudolanguage is Xcode's
double-length and right-to-left pseudolanguages together: every localized string twice, in a
mirrored layout, with English text, so a string that isn't localized stands out. The book's
title is server data, so `item.title` is "Pride and Prejudice" in every language.

Each test attaches screenshots of Home, Library and the item, named `<prefix>-home`,
`<prefix>-library` and `<prefix>-item`, and keeps them even when it passes. To get them as PNGs:

```sh
ABS_UI_PLATFORM=ios mise run test:ui -- -only-testing:AudiobookshelfUITests/LocalizedSmokeTests -resultBundlePath /tmp/ui.xcresult
xcrun xcresulttool export attachments --path /tmp/ui.xcresult --output-path /tmp/ui-screens
```

`manifest.json` in the output maps each exported file to its name (`suggestedHumanReadableName`).
CI runs the localized tests with the rest (about 25 seconds each on the simulator).

App Store screenshots use the same journey; see [screenshots.md](screenshots.md).

Not covered yet (#46): HLS and podcast playback fixtures.
