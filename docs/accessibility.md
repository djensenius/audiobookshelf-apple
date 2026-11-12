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
  - a value: the progress ("Progress, 45%" or "Finished"), then the Explicit, Abridged and
    Missing badges (`ItemPresentation.accessibilityValue`);
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
  card adds a check next to its title (`ItemPresentation.showsFinishedCheck`).
- **Strings.** New labels, values and hints go through `Localization/native/en-us.json` and
  `mise run strings` ([localization](localization.md)). Never build a spoken string by hand
  from numbers; use `DurationStyle.accessibilityString` and the percent format.

## Audit checklist per screen

Check each item with VoiceOver, Voice Control and, on the Mac, Full Keyboard Access, at the
default text size and at AX5. Record failures as issues that reference #106.

### Home

- [ ] Each shelf title is a heading, and the rotor's Headings jump between shelves.
- [ ] Each card reads its title, author, series, then progress, as one element with Open
  Details as its hint.
- [ ] The Actions rotor offers the card's context-menu actions.
- [ ] "Show All" names its shelf.
- [ ] Voice Control: "Tap" plus a card's title opens it.
- [ ] The refresh failure row reads its message and its Retry button.

### Library

- [ ] Grid and list cells read as cards and rows (above).
- [ ] The toolbar's filter, sort and layout buttons have names.
- [ ] Collapsed series read their name and book count.
- [ ] Collections and playlists read their name and item count.

### Item detail

- [ ] The title, author, narrator and series read in order, with section titles as headings.
- [ ] Play, Download and the More menu have names and values (time left, download progress).
- [ ] The description's Read more and Read less are buttons, and the text resizes without
  animation with Reduce Motion.
- [ ] Chapters and files read as rows, and episodes read their date, badges and summary.

### Player

- [ ] The scrubber reads "Progress", then the elapsed and remaining time; swiping up and
  down jumps by the jump interval settings.
- [ ] Play or Pause, the jumps, the chapter buttons, speed, sleep timer and bookmarks have
  names, and toggles report their state.
- [ ] The cover is hidden or named, and the chapter title reads once.
- [ ] With Reduce Motion, the thumb doesn't animate as it grows.
- [ ] Voice Control: "Tap Play", "Tap Pause" and the jump buttons work by name.

### Settings

- [ ] Section headers are headings.
- [ ] Each toggle, picker and stepper reads its label and value.
- [ ] The language row explains where the setting lives on the Mac.

### Downloads

- [ ] Each download reads its title, state and progress.
- [ ] Delete and Cancel are actions on the row as well as buttons.
- [ ] Downloaded state reaches cards and rows once the downloads model lands (#385).

## Dynamic Type up to AX5

- Text uses text styles, and sizes use `@ScaledMetric`; check every screen at AX5.
- `ItemRow` stacks the cover above the text at accessibility sizes (`AdaptiveStack`).
- Cards keep two lines for their title (`lineLimit(2, reservesSpace: true)`); at AX5 the
  shelves get taller rather than truncating more.
- Touch targets stay at least 44 × 44 points, and the scrubber's track grows with its thumb.
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

There's no UI test target yet. When #46a adds one and its `test:ui` task, part two of #106
(106b) adds audit tests there:

- one test per screen above that launches the app with fixture data, opens the screen and
  calls `XCUIApplication.performAccessibilityAudit()`, failing on any issue it reports;
- known false positives filtered by audit type and element, each with a comment and an
  issue;
- the same tests run at AX5 through the launch environment.

Until then, package tests cover the pure helpers: the labels and values in `ItemViewsTests`,
and the Voice Control names and Reduce Motion helpers in `AccessibilityTests`.

## Known gaps

- Cards and rows don't say whether an item is downloaded: `ItemSummary` doesn't carry it yet.
  The downloads work (#385) adds it.
- Series and author cards have no context menu, so they have no custom actions to mirror.
- The connection indicator tells a metered connection from an unmetered one by colour alone;
  its message, which is its value and tooltip, says which.
