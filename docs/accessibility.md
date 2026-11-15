# Accessibility

How the app supports VoiceOver, Voice Control, Full Keyboard Access, Dynamic Type, Reduce
Motion and Differentiate Without Color, and the checklist to audit each screen against
(issue #106). The shared views in ABSUI carry most of it, so a screen built from them gets
it for free; app-side views follow the same rules.

## Rules for views

- **Cards and rows are one element.** `ItemCard`, `ItemRow`, `SeriesCard`, `AuthorCard` and
  the app's `GroupCard` use `accessibilityElement(children: .ignore)` with:
  - a label: the title, then the author or narrator, then the series
    (`ItemPresentation.accessibilityLabel`); a row adds the spoken duration;
  - a value: the progress ("Progress, 45%" or "Finished"), "Downloaded" when the item is
    downloaded on this device (`itemDownloadReader`), then the Explicit, Abridged and Missing
    badges (`ItemPresentation.accessibilityValue`);
  - the Open Details hint and the `.isButton` trait;
  - Voice Control names (`cardInputLabels(title:label:)`): the visible title first, then the
    full label, so "Tap Dune" works without speaking the series.
- **Custom actions mirror the context menu.** `itemActions(_:perform:)` adds the same
  `ItemAction`s, with the same titles, as VoiceOver actions. Don't add a menu entry without
  its action.
- **Decorative images are hidden.** Covers inside a card or row use
  `CoverView(accessibility: .hidden)`, and icons next to text are `accessibilityHidden`.
- **Progress has a value.** `ProgressRing`, `ProgressBadge` and `ProgressBarOverlay` speak
  their percentage; a bar whose element already speaks it is hidden.
- **Headings.** Shelf titles (`ShelfRow`) and detail-screen section titles carry `.isHeader`,
  so the VoiceOver rotor can jump between them. `List` section headers get it from the
  system.
- **The scrubber is adjustable.** `PlayerScrubber` is one element named Progress. Its value
  is the elapsed and remaining time in words, in the app's language. Swiping up and down
  calls the player's jump forward and back, which use the jump interval settings.
- **Reduce Motion.** Custom animations take `accessibilityReduceMotion` and drop to no
  animation through a static helper that tests cover, for example
  `ProgressRing.animation(reduceMotion:)`, `PlayerScrubber.thumbAnimation(reduceMotion:)`,
  `ExpandableText.toggleAnimation(reduceMotion:)` and `ConnectionStatus.pulses(reduceMotion:)`.
  The cover fade-in is a short cross-fade, which Reduce Motion allows.
- **Differentiate Without Color.** When colour is the only cue, add a shape. A finished
  card adds a check next to its title (`ItemPresentation.showsFinishedCheck`). The downloaded
  mark is a down-arrow symbol, not a colour: a black arrow on the green success circle
  (7.56:1, above the 3:1 non-text minimum).
- **Strings.** New labels, values and hints go through `Localization/native/en-us.json` and
  `mise run strings` ([localization](localization.md)). Never build a spoken string by hand
  from numbers; use `DurationStyle.accessibilityString` and the percent format.

## Audit checklist per screen

Check each item with VoiceOver, Voice Control and, on the Mac, Full Keyboard Access, at the
default text size and at AX5. Record failures as issues that reference #106.

### Home

- [ ] Each shelf title is a heading, and the rotor's Headings jump between shelves.
- [ ] Each card reads its title, author, series, then progress and Downloaded, as one element
  with Open Details as its hint.
- [ ] The Actions rotor offers the card's context-menu actions.
- [ ] "Show All" names its shelf.
- [ ] Voice Control: "Tap" plus a card's title opens it.
- [ ] The refresh failure row reads its message and its Retry button.

### Library

- [ ] Grid and list cells read as cards and rows (above).
- [ ] The toolbar's filter, sort and layout buttons have names.
- [ ] In compact width, the root's section menu reads "Browse" with the section shown as its
  value, and its entries read their titles, the shown one selected. At accessibility text
  sizes, long-pressing it shows the Large Content Viewer.
- [ ] Collapsed series read their name and book count.
- [ ] Collections and playlists read their name and item count.

### Item detail

- [ ] The title, author, narrator and series read in order, with section titles as headings.
- [ ] Play, Download and the More menu have names and values (time left, download progress).
- [ ] The description's Read more and Read less are buttons, and the text resizes without
  animation with Reduce Motion.
- [ ] Chapters and files read as rows, and episodes read their date, badges and summary.
- [ ] Each metadata link reads its name and its label ("Jane Austen, Author, link"), and
  each plain row reads as one element ("Duration, 11 hours 36 minutes"); the labels
  themselves are hidden. Each link and row is at least 44 points tall (#612).

### Player

- [ ] The scrubber reads "Progress", then the elapsed and remaining time; swiping up and
  down jumps by the jump interval settings.
- [ ] Play or Pause, the jumps, the chapter buttons, speed, sleep timer and bookmarks have
  names, and toggles report their state.
- [ ] The cover is hidden or named, and the chapter title reads once.
- [ ] With Reduce Motion, the thumb doesn't animate as it grows.
- [ ] The total track (when shown) reads "Total Track" with both times; its times use
  `.caption`, as the chapter's do (#614).
- [ ] Voice Control: "Tap Play", "Tap Pause" and the jump buttons work by name.

### Settings

- [ ] Section headers are headings.
- [ ] Each toggle, picker and stepper reads its label and value.
- [ ] The language row explains where the setting lives on the Mac.

### Downloads

- [ ] Each download reads its title, state and progress.
- [ ] Delete and Cancel are actions on the row as well as buttons.
- [ ] A downloaded item's card and row show the mark and read "Downloaded" in their value; it
  appears when the download completes and goes when it's deleted.

## Dynamic Type up to AX5

- Text uses text styles, and sizes use `@ScaledMetric`; check every screen at AX5.
- `ItemRow` stacks the cover above the text at accessibility sizes (`AdaptiveStack`).
- Cards keep two lines for their title (`lineLimit(2, reservesSpace: true)`); at AX5 the
  shelves get taller rather than truncating more.
- Touch targets stay at least 44 × 44 points, and the scrubber's track grows with its thumb.
  The item screen's metadata rows are padded to 44 points tall (#612).
- The mini player (the tab bar's bottom accessory on iOS) stops growing its text at xLarge
  (`MiniPlayerView.largestTextSize`): the system gives the accessory a fixed height, which fits
  two lines up to that size, as the tab bar keeps its own size. At accessibility sizes it shows
  the title on up to two lines, play/pause and close; in narrow windows (iPhone Duo) a
  `ViewThatFits` drops the jumps, then the cover and author, so the title keeps about a dozen
  characters (#616). Its button speaks the full title. Since its text is capped at xLarge, a
  long press on the title, play/pause, the jumps or close shows the Large Content Viewer, as on
  the tab bar. At accessibility sizes, where the viewer works, the title's long press shows it
  in place of the Up Next context menu; Up Next stays in the full player and in VoiceOver's
  actions. `MiniPlayerTests` (UI tests) checks the narrow layout and which of the two the long
  press gets; XCUITest can't see the viewer's HUD, which closes when the press ends.
- The full player's column (the artwork at 45% of the screen's height, then the titles,
  scrubber and controls) scrolls when it's taller than the screen, as at AX5 on an iPhone 17,
  and opens scrolled to its end (`defaultScrollAnchor(.bottom, for: .initialOffset)`), so the
  controls show and the artwork's top scrolls away. Where it fits, nothing moves (#623).
- Previews at `.accessibility5` exist for `ItemCard` and `ItemRow`; add one for any new
  view whose layout changes with the text size.

## Mac keyboard access and Voice Control

- With Full Keyboard Access, Tab reaches every control, and cards are focusable as buttons.
- Menu commands cover the main actions: Go (`GoCommands`), Refresh (`RefreshCommand`), Search
  (`SearchCommands`) and the player's commands, each with its shortcut.
- Voice Control's Show Names shows each card's title (its first input label), and Show
  Numbers reaches every control, including the scrubber.
- The connection indicator's message is its tooltip (`help`) as well as its value.

## Manual VoiceOver run-through

For QA (#210) to fill in on each release candidate. Note the device, OS and build, then
walk each screen with VoiceOver and record what you hear against what's expected.

| Screen | Device and OS | Build | Result | Notes |
| --- | --- | --- | --- | --- |
| Home | | | | |
| Library | | | | |
| Item detail | | | | |
| Player | | | | |
| Settings | | | | |
| Downloads | | | | |

## Automated audits

`AccessibilityAuditTests` (in `AudiobookshelfUITests`; see docs/testing/ui-tests.md) signs in
to the fixture server, opens each screen above in turn (`FixtureScreen`, in order: Home,
Library, Item detail, Player, Settings, Downloads) and calls
`XCUIApplication.performAccessibilityAudit(for:)` on it. Each issue the audit reports fails the
test with its screen, text size, audit type, element and description, for example
`Player (default text size): contrast on text label 'Jane Austen': Contrast nearly passed`, and
a screenshot of the screen, `audit-<screen>`, is attached. Two tests walk every screen, one
launch each:

- `testScreens`, at the default text size, with every audit type but Dynamic Type and clipped
  text. At this size those two predict larger sizes, and report text that does scale and
  doesn't clip (a `Form` row's label, the player's times);
- `testScreensAtAccessibilitySize`, at AX5 (`-UIPreferredContentSizeCategoryName
  UICTContentSizeCategoryAccessibilityXXXL`), with every audit type;
- `testScreensInDarkTheme` and `testScreensInBlackTheme`, `testScreens` again in the dark and
  black themes (#641). On iOS they also walk the screens with an accent-filled
  (`.borderedProminent`) button the fixtures reach (#645, `FixtureScreen.accentButtonScreens`):
  Missing item (Emma, which has no item fixture, so Item detail shows its error state and Retry),
  Bookmarks (the player's bookmarks sheet and its Create Bookmark, at the large detent) and
  Series (Barsoom, with Continue Series).

A newly created simulator, as on CI, ignores `XCUIDevice.shared.appearance` and `simctl ui
appearance dark` until it's rebooted, so the dark passes don't switch the simulator. They launch
with `-ABSTheme dark` or `-ABSTheme black` (docs/testing/ui-tests.md), which sets the fixture
launch's theme setting; the theme applies `preferredColorScheme` at each scene's root, and the
full player and sheets follow it. Before each audit the test checks the screen really is dark
(`assertAppearance`: over half the screenshot's pixels under half brightness; light screens
are mostly white), so a pass can't quietly audit light mode. The black theme gets its own pass
because its backgrounds are true black and its muted text and borders have their own values. The
three passes at the default size take about 70–80 seconds each on an iPhone 17.

The player is paused before its audit, so its times hold still. Downloads is audited in its
empty state: fixture launches have their own empty download stack. CI runs them on iOS with the
other UI tests; on macOS they build but don't run yet (#46).

Item detail's Chapters and Audio Tracks headers are below the metadata, so the walk never has
them on screen. `ItemDetailSectionsAuditTests` (iOS) scrolls them clear of the tab bar
(`item.chapters`, `item.tracks`) and audits contrast there, failing only for issues on the
headers. Their counts took the disclosure group's accent tint, 2.7:1 on the `ABSColor.border`
capsule in light and 3.7:1 in dark; they now use `ABSColor.foreground`, 8.3:1 and 6.5:1
(#638). `testSectionHeadersContrastInDarkTheme` audits them again in the dark theme.

The first dark passes (#641) found, measured from iPhone 17 screenshots (text against the pixels
behind it):

- Item detail's Play button: white on the dark accent (`#4FC3CC`), 2.1:1, "Contrast failed" in
  dark and black. The `.borderedProminent` label now uses `ABSColor.onAccent`, white on the light
  accent (4.9:1, unchanged) and `rgb(35, 35, 35)` on the dark one, 7.5:1.
- The same white label on every other `.borderedProminent` button (#645): Series' Continue
  Series, a collection's or playlist's Play All, a podcast's Next Episode, an episode's play, the
  episode feed's download, Bookmarks' Create Bookmark, the readers' "Read in browser" and
  `ErrorStateView`'s Retry. They, and Play, now use `ABSColor.onAccent` through
  `onAccentForeground()`, only while enabled: a disabled `.borderedProminent` button keeps the
  style's dimmed label on its grey fill, which an explicit colour would override (white on light
  grey in light). Create Bookmark measures 7.5:1 in dark. With white they fail the dark pass:
  Create Bookmark (and its time) on Bookmarks, Continue Series (and the book's title in it) on
  Series. Groups, Podcasts, episodes and the readers have no fixtures, so the audits don't open
  them.
- The mini player's author ("Jane Austen") on its glass: in dark the glass takes a lighter tint
  from the rows under it, `rgb(87, 88, 88)` over Settings, where `mutedForeground` is 2.7:1
  ("Contrast failed"); in black, 3.2:1 on Settings and 4.0:1 on Downloads ("nearly passed").
  The mini player's secondary text and Close button now use `ABSColor.mutedForegroundOnGlass`:
  5.1:1 on that dark glass and 9.4:1 on the black theme's; light is unchanged, 5.5:1.
- The Player in the black theme: "Chapter 1", the author and the elapsed times in
  `mutedForeground`'s black value, legacy's `rgb(120, 126, 132)`, are 3.5–3.6:1 on the player's
  backdrop, which is tinted by the cover (`rgb(47, 40, 38)`), not black ("nearly passed"). The
  black theme now uses dark's `rgb(156, 161, 167)`: 5.6:1 there and 8.1:1 on black.
- Item detail's navigation title ("Pride and Prejudice"), flagged "nearly passed" in a manual
  dark audit during #638, isn't reported at rest: it measures 11.7:1 in dark and 21:1 in black.
  It's the system's title, drawn in the label colour, so content scrolled under it is the only
  thing that can lower it.

Known issues are filtered in `KnownAuditIssue.all`, by screen, audit type, description and
element, each with the reason and its issue:

- Item detail: "potentially inaccessible text" with no element (#613). These are the labels of
  the metadata's link rows (Author, Narrator, Genres), hidden from VoiceOver on purpose: each
  link speaks its label ("Jane Austen, Author, link"), since VoiceOver often skips a
  container's label. Bisected on the iPhone Duo simulator: with the labels shown to VoiceOver
  there are no reports; with only the link rows' labels hidden there are three, one per label.
  The plain rows' hidden labels aren't reported because their row's own label is the same text.
  Giving the links' container that label (`.contain`) doesn't help, and showing the labels
  would add a VoiceOver stop per row that repeats what the links already say, so this is a
  false positive, kept filtered.
- Cards' titles and authors on Home and Library, which they cut short by design and speak in
  full (#615; only text inside an `item.<id>` card, not the item screen's own `item.`
  elements), count as clipped text. See "Decisions".
- Library at AX5: "Dynamic Type font sizes are partially unsupported" on the first card's
  title and author, about one run in ten on the iPhone Duo (#622), though both use text styles
  and scale. The audit steps the text size from the smallest up to AX5 in about a second.
  Where it crosses into the accessibility sizes, the grid drops from two columns to one
  (`ItemGridMetrics.minimumCellWidth`). A screen recording of a failing run shows the app
  still drawing the first accessibility size about 0.3 seconds after that relayout, then
  jumping ahead, so the audit measured the text not growing. The cover had loaded long
  before, so waiting before the audit doesn't help. This is a timing false positive, kept
  filtered: only "partially unsupported", only on Library and only for text in an `item.<id>`
  card. Home audits the same card unfiltered, and its shelf has no columns to change, so a card
  font that really doesn't scale still fails there.
- Contrast on text that has scrolled under the bottom bar, on every screen but the Player
  (#623). On iOS the tab bar floats over the content, with the mini player above it, so a
  screen at rest has rows under the bar's glass, and the audit measures them through it. On an
  iPhone 17 (6.3-inch, iOS 27.2) that's Item detail's "Size" (y 818–836 of 874, under a tab
  bar from y 791), "Duration" at AX5 and Settings' last two rows; the same rows pass above the
  bar. Only text whose frame overlaps the tab bar or the mini player (`player.mini`), and not
  the bar's own text, is filtered. The full player covers the bar, so the Player isn't. Item
  detail's metadata labels are hidden from VoiceOver (each value speaks its label), so the
  audit can report one under the bar with no element ("Contrast failed for
  SwiftUI.AccessibilityNode"), as it did once in four runs for "Duration" at AX5. That isn't
  filtered but deferred: when Item detail has a contrast issue with no element while its
  metadata (`item.metadata`) overlaps the bar, the test scrolls the content up by half the band
  between the navigation bar and the bar at a time, auditing contrast at each step, until the
  metadata ends above the bar. So every row that was under the bar is audited in full view
  (metadata taller than the band, as at AX5, in overlapping segments), and any issue with no
  element in those audits fails. Named text the scroll brings on screen isn't judged by them.
- Settings in the dark theme: "Potentially inaccessible text" with no element, while a row's
  text is under the mini player (#641). The dark glass shows the text through, and the audit
  finds the mini player, not the row, on top of it. Probed on an iPhone 17: there's no issue
  without the mini player; with it, the issue comes and goes as Settings scrolls "Allow position
  seeking on media notification controls" under it and away, and that row's toggle speaks the
  text. Only filtered on Settings, with no element, while content text overlaps the tab bar or
  the mini player.
- The mini player's text on the iPhone Duo in the dark and black themes, "Contrast failed"
  every run (#641): the title on Downloads in both, and the author on Settings in dark. A
  screenshot taken as each issue arrives, in the element's frame, measures 16.3:1 for the title
  (white on the glass's `rgb(32, 32, 32)`) and 5.9:1 for the author (`rgb(214, 218, 222)` on
  `rgb(78, 79, 79)`). The frames match the text, and the issues stay after waiting for the
  screen to be pixel-still for a second, so it isn't the glass mid-transition. They don't
  happen on an iPhone 17, where the mini player sits above the tab bar instead of floating at
  the bottom. Filtered only for the mini player's text, and only while a screenshot taken then
  measures 4.5:1 or more locally (`MeasuredContrast`). The text's pixels are the ones in the
  colour the app draws it in for the theme, not guessed from the image: white for the title
  (SwiftUI's primary label) and `ABSColor.mutedForegroundOnGlass` for the author, mirrored in
  `FixtureTheme`. That colour only picks the pixels out: each is measured in the colour it's
  actually drawn in, against the median of the non-text pixels 2–4 pixels around it, past the
  anti-aliased edge, taking the 10th percentile. So text that really fails, as the
  author did at 2.7:1, or that crosses a lighter patch of glass, still fails. The issue isn't
  filtered when fewer than 20 pixels are in the expected colour (as when the app's colour
  changes and the test's doesn't), or when over a quarter of them have too little background
  around them to measure, as a patch of background in the text's colour would; the real
  glyphs have none.
- The Player's remaining times, "Contrast failed" on the chapter's ("-0:26") on an iPhone 17
  every run (#623). Its pixels measure 5.7:1 on the backdrop, and the elapsed time's beside
  it, which passes in the same font and colour, 5.6:1. This is the false positive the
  whole-book remaining time had at `.caption2` (#614), so only text on the Player that's a
  minus and a timestamp is filtered.
- Bookmarks' Done (`player.sheet.done`) in the dark theme, "Contrast failed" every run on an
  iPhone 17 (#645): the system's glass button in the sheet's navigation bar. Its white label
  measures 12.2:1 on the glass's `rgb(49, 55, 47)`. At the sheet's medium detent, glass over the
  player, the audit also failed "No Bookmarks" (12.6:1) and Done (8.5:1), so the walk drags the
  sheet to its large detent first. Filtered only for that button, and only while a screenshot
  measures white text at 4.5:1 or more there (`MeasuredContrast`), as for the mini player. Series
  is in the bottom-bar filter above: its third card's author rests under the mini player and the
  tab bar on an iPhone 17.

Two findings that used to be filtered are fixed instead. The Player's whole-book remaining time
failed contrast at `.caption2` (11 points), though its pixels measure as the elapsed time's do,
about 5.4:1 on the backdrop; it now uses `.caption`, like the chapter's times, and passes
(#614). The mini player's title, cut to a letter on the iPhone Duo, keeps a readable width
(#616; see "Dynamic Type up to AX5").

On an iPhone 17 at AX5 the Player's play/pause button was below the fold; the player now
opens scrolled to its controls (#623; see "Dynamic Type up to AX5").

Add a filter only for an issue that isn't the app's to fix or that has its own issue; fix the
rest. Package tests cover the pure helpers: the labels and values in `ItemViewsTests`, and the
Voice Control names and Reduce Motion helpers in `AccessibilityTests`.

## Known gaps

- Cards and rows mark completed downloads only; a download under way shows nothing until it
  completes.
- Series and author cards have no context menu, so they have no custom actions to mirror.
- The automated audits' known issues above, and the screens they don't open yet (sheets,
  search, series, authors, collections, playlists, stats and CarPlay; the dark passes open
  Bookmarks and a series, #645).

### Decisions

- Cards keep cutting their title at two lines and their author at one, at every text size,
  like Apple Books (#615). More lines would make the cards, already taller at large sizes,
  taller still, showing fewer books at a time; and the card, one accessibility element, speaks both in full, so nothing
  is lost to VoiceOver; the full text is also on the item screen. The audit's clipped-text
  reports for cards are filtered (above).
- The connection indicator tells a metered connection from an unmetered one by colour alone;
  its message, which is its value and tooltip, says which.
- In a vertical bar (the iPhone Duo's outer display), the Library section menu shows its
  symbol only and reads "Browse" without the section shown: the bar drops a `Label`'s
  accessibility value, as it does for View Options. Its overflow menu entry is titled with the
  section.
