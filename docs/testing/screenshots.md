# App Store screenshots

`mise run screenshots` (`scripts/screenshots.sh`) takes the App Store screenshots from the fixture
server (`-ABSFixtures`, [ui-tests.md](ui-tests.md#the-fixture-server)), so no Audiobookshelf server
or account is needed. Fastlane isn't used.

```sh
mise run screenshots                                   # iphone-6.9, ipad-13 and duo-outer, in en-US
mise run screenshots -- --device ipad-13 --locale de-DE
mise run screenshots -- --device duo-inner             # in a terminal; asks you to unfold the Duo
mise run screenshots -- --device mac                   # needs Automation Mode
```

The images go to `build/screenshots/<locale>/<device>/<screen>.png` (git-ignored). The result
bundles and exported attachments stay in `.build/screenshots/`. Every run replaces the images of
the devices and locales it runs.

## Devices and sizes

| Device | Simulator or platform | Pixels (portrait) | App Store Connect slot |
| --- | --- | --- | --- |
| `iphone-6.9` | iPhone 18 Pro Max | 1320 × 2868 | iPhone 6.9" display |
| `ipad-13` | iPad Pro 13-inch (M5) (16GB) | 2064 × 2752 | iPad 13" display |
| `duo-outer` | iPhone Duo, folded (outer display) | 1398 × 2034 | iPhone Duo outer display |
| `duo-inner` | iPhone Duo, unfolded (inner display) | 2007 × 2853 | iPhone Duo inner display |
| `mac` | macOS, full screen on the main display | 2880 × 1800 | Mac |

Without `--device`, the script runs `iphone-6.9`, `ipad-13` and `duo-outer`, and lists
`duo-inner` and `mac` as skipped. `--device` and `--locale` (a BCP 47 tag, default `en-US`) can be
repeated. The script checks every image's size with `sips` and exits non-zero if a screen is
missing or the wrong size, or if a test fails.

For each simulator device the script:

1. builds the app and tests for the iOS Simulator once (`build-for-testing`, into
   `.build/DerivedData`, two jobs);
2. creates its own simulator, `abs-shots-<device>-<pid>`, and boots it;
3. sets a clean status bar: 9:41, full Wi-Fi and cellular bars, no carrier name, battery 100%
   (`simctl status_bar … override`);
4. runs `ScreenshotTests` once per locale (`test-without-building`), with the result bundle in
   `.build/screenshots/<locale>-<device>.xcresult`;
5. exports the attachments (`xcresulttool export attachments`) and copies each `appstore-<screen>`
   one to `<screen>.png`.

It deletes its simulators when it exits, on failure or Control-C too.

## The tests

`ScreenshotTests` (`AudiobookshelfUITests/ScreenshotTests.swift`) signs in to the fixture server
with `-AppleLanguages (<tag>) -AppleLocale <tag>` and attaches a screenshot of the whole main
screen, status bar included, of Home, Library and *Pride and Prejudice*'s detail, named
`appstore-home`, `appstore-library` and `appstore-item`. On a Mac it first makes the window full
screen.

The class is skipped unless the test runner's environment has `ABS_SCREENSHOTS=1`. The script sets
it with `TEST_RUNNER_ABS_SCREENSHOTS=1` and selects the class with
`-only-testing:AudiobookshelfUITests/ScreenshotTests`, so `mise run test:ui` and CI list it as
skipped without launching the app. To run it by hand:

```sh
TEST_RUNNER_ABS_SCREENSHOTS=1 ABS_UI_PLATFORM=ios mise run test:ui -- -only-testing:AudiobookshelfUITests/ScreenshotTests
```

Player, Downloads and Settings aren't captured yet (#109).

The fixture library is public-domain LibriVox material. Every item has the same cover,
`Audiobookshelf/Fixtures/Resources/fixture-cover.png`: an 8 × 8 single-colour placeholder made for
this repository, not artwork from anywhere else, so the screenshots contain nothing under someone
else's copyright.

## iPhone Duo

The Duo simulator has two integrated displays: the outer `LCD` (screen 1, 1398 × 2034) and the
inner `LCD-1` (screen 3, 2007 × 2853); `xcrun simctl io <udid> enumerate` lists them. A new
simulator boots folded, on the outer display, so `duo-outer` is automatic and shows the compact
iPhone layouts.

The inner display needs the device unfolded, and nothing in `simctl` or XCUITest does that in Xcode
27.2: powering the outer display off (`simctl io <udid> screenConfig --display=1 power off`) leaves
the inner one black, and the only control is the hinge slider in DeviceHub's device chrome. So
`--device duo-inner` creates and boots the simulator, opens DeviceHub and waits for you to drag the
hinge fully open and press Return before running the tests; it fails straight away when not run in
a terminal. The size check catches a run that wasn't unfolded. Unfolded, the app should show its Duo
layouts (ADR 0004), such as the cover grid kept clear of the fold; this path hasn't been run yet.

## Mac

The Mac screenshots run the same tests on macOS, signed ad hoc as `mise run test:ui` is. XCUITest on
macOS needs Automation Mode ([ui-tests.md](ui-tests.md#run-them)); while it's disabled,
`--device mac` fails with the command that enables it (#46). The test makes the app full screen and
captures the main display, so use a 16:10 display: an image of another 16:10 size, such as
3360 × 2100, is scaled to 2880 × 1800, and any other size fails the check.

## Uploading

App Store Connect › the app › the version being prepared:

1. Pick the platform (iOS or macOS) and the localization in the top-right menu.
2. Under *Previews and Screenshots*, open the matching slot from the table above, for example
   *iPhone 6.9" Display*, *iPad 13" Display* or the iPhone Duo outer and inner displays, and drag
   in `build/screenshots/<locale>/<device>/*.png` in the order to show them (up to ten per slot).
3. Repeat for each localization that has its own screenshots; the others fall back to the primary
   language.
4. Save. App Store Connect rejects an image of the wrong size, which the script has already checked.

Check the images before uploading: they show fixture data, so make sure no screen shows a loading
or error state.
