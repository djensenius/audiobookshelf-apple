# Localization

The flat JSON files in `strings/` are legacy data synced from upstream
([advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app)), where
translators edit them in Weblate. They are read-only here, like the rest of the legacy
code. Keys only the native app needs live in `Localization/native/`. `mise run strings`
merges both into the String Catalog the native app uses:

```
strings/*.json + Localization/native/*.json
  ── mise run strings ──▶  Packages/AudiobookshelfKit/Sources/ABSUI/Resources/Localizable.xcstrings
```

Weblate can't edit `.xcstrings` files
([WeblateOrg/weblate#10848](https://github.com/WeblateOrg/weblate/issues/10848)), so
never edit the catalog by hand or in Xcode's catalog editor: the next import overwrites it.

## Commands

| Command | What it does |
| --- | --- |
| `mise run strings` | Regenerate `Localizable.xcstrings` and print warnings for skipped translations |
| `mise run strings:check` | Fail if the catalog or the app's `CFBundleLocalizations` is out of date, or the Swift sources fail the [source checks](#source-checks) (runs in CI) |
| `mise run test:tools` | Test the importer (runs in CI) |

The importer is the local package `Tools/StringsImport` (library `StringsImportCore`, executable
`import-strings`). It is not part of the app or `AudiobookshelfKit`.

## Adding a string

1. If an upstream key already says what you need, use it. Otherwise add the key and
   English text to `Localization/native/en-us.json`, keeping keys sorted and using the
   legacy conventions (`Button…`, `Header…`, `Label…`, `Message…`; `{0}` placeholders;
   `<strong>` for emphasis). Translations can go in `Localization/native/<file>.json`,
   named like the `strings/` files (`de.json`, `no.json`, `pt-br.json`).
2. Run `mise run strings` and commit the JSON and the catalog.
3. Use the key from Swift: `L10n.string("ButtonCancel")`,
   `L10n.string("LabelByAuthor", author)`, or `L10n.attributed("HeaderWelcome", name)` for
   values with Markdown.

### Plurals

A native key whose text depends on a number is a JSON object of CLDR plural categories
instead of a string, with `other` required and the count `{0}` in every form:

```json
"SharedBookCount": {
  "one": "{0} book",
  "other": "{0} books"
}
```

The importer writes it as the catalog's plural variations, with `{0}` as the integer
`%1$lld` (the String Catalog compiler requires the count in every form). Look it up with
`L10n.plural("SharedBookCount", count: 1)`, which picks the form and formats the count for
the locale; never with `L10n.string`. Translations in `Localization/native/<file>.json` are
objects too, with the categories their language uses. A locale without one gets no entry
(unlike strings, which get English marked "new"): Foundation would pick copied English forms by
that locale's plural rules ("1 books" in Japanese, "0 book" in French). `L10n.plural` instead
falls back to the English forms picked by English rules, with the count still formatted for the
locale.

The importer fails if a native key also exists in `strings/`; pick another key. Native
keys nobody has translated get the English fill like any other key.

### App Intents

App Intents titles, parameters and error dialogs resolve their `LocalizedStringResource` in the
bundle that declares the intent (the app, or the widget extension for the shared intents), not
in ABSUI's package bundle, so `L10n` can't serve them. Their keys start with `Intent` and live in
`Localization/intents/en-us.json` (translations in `<file>.json` beside it); `mise run strings`
writes them to `AudiobookshelfShared/Intents/AppIntents.xcstrings`, which both targets compile.
Use them as `LocalizedStringResource("IntentPauseTitle", table: "AppIntents")`.

App Shortcut phrases are the exception: Apple requires them to be English literals in the
`AppShortcutsProvider`, with translations in an `AppShortcuts.xcstrings` catalog keyed by the
English phrase. None are translated yet.

Translations arrive through the upstream sync ([upstream-sync.md](upstream-sync.md)), not
through Weblate commits to this repository; rerun `mise run strings` after syncing
`strings/`. If upstream adds a locale, the importer either maps it or fails with a message
asking for an entry in `LocaleMapping.overrides`; then add the new identifier to
`CFBundleLocalizations` in `Audiobookshelf/Info.plist` (`strings:check` prints the list).
That plist is shared by the iOS and macOS app (one multiplatform target), and `strings:check`
fails unless it lists exactly the imported locales. The widget extension's plist has no
`CFBundleLocalizations` because the widget shows no localized text yet; add the list there,
and to the check, when it does.

## Using strings in Swift

- `L10n.string` returns plain text, with any markup (bold) removed. `L10n.attributed`
  renders the localized value's inline Markdown (bold, line breaks kept). Both insert the
  arguments as plain text.
- Never run Markdown over formatted output (`AttributedString(markdown: L10n.string(…))`
  or `Text(LocalizedStringKey(…))`): arguments are often server data such as user names or
  titles, and would be parsed as links or formatting.
- In ABSUI, look strings up only through `L10n` (which always uses `bundle: .module`) and
  use `Text(verbatim:)` for literals that aren't localized. A `Text("…")` literal or
  `String(localized:)` call in ABSUI would let Xcode's string extraction add entries to
  the catalog, which then fails `strings:check`.

## Source checks

`mise run strings` and `strings:check` also scan the Swift sources (`Audiobookshelf/` and
`Packages/AudiobookshelfKit/Sources/`), skipping comment lines:

- **Missing keys fail.** A key is the literal first argument of `L10n.string`, `L10n.attributed`
  or `L10n.plural`, or any identifier-like literal named like a key (`"Button…"`, `"Header…"`,
  `"Label…"`, `"Message…"`, `"Note…"`, `"Placeholder…"`, `"Shared…"`, `"Toast…"`, `"Unit…"`
  followed by an uppercase letter or digit), because keys often reach `L10n` through a
  `titleKey` property or a ternary. Each must exist in `strings/en-us.json` or
  `Localization/native/en-us.json`; the error gives `file:line`. Keys built at run time
  (`"Label" + name`) aren't seen; don't build keys that way.
- **Unused keys warn.** A key in either `en-us.json` that no Swift literal names is listed,
  separately for native and legacy keys. Many legacy keys are kept for features not ported yet,
  so this never fails.
- **Hard-coded strings in `Audiobookshelf/Features/` and ABSUI fail.** A literal with a letter (outside its
  interpolations) passed straight to `Text`, `Text(verbatim:)`, `Button`, `Label`, `Toggle`,
  `Picker`, `Section`, `Menu`, `TextField`, `SecureField`, `Link`, `LabeledContent`,
  `ContentUnavailableView`, `ProgressView`, `GroupBox`, `DisclosureGroup`, `Tab`,
  `.navigationTitle`, `.navigationSubtitle`, `.accessibilityLabel`, `.accessibilityHint`,
  `.accessibilityValue`, `.help`, `.alert`, `.confirmationDialog`, or a `prompt:` argument is
  reported with `file:line`, unless it is a key. Symbols and numbers (`Text(verbatim: "•")`) pass.
  Only single-line literals on the call's line are seen. Previews (`#Preview { … }` and types or
  extensions whose inheritance clause lists `PreviewProvider`, even on a later header line; a
  generic constraint or `where` clause naming it doesn't count) and the branch of a conditional
  that is exactly `#if DEBUG` are skipped; `#elseif DEBUG` and compound conditions such as
  `#if DEBUG || os(macOS)` are checked.
- **The baseline only shrinks.** `Localization/hardcoded-strings-baseline.txt` lists strings
  accepted until they're localized, one per line as `<file path><TAB><trimmed source line>`,
  matched by file and source rather than line number. A string with no entry fails, and so does
  an entry that no longer matches one: localize the string, then delete its entry. It was empty
  when introduced; don't add entries for new code. An entry that the target branch's baseline
  doesn't have (counting duplicates) fails too. That base is `--baseline-base <ref>`, else
  `STRINGS_BASELINE_BASE` (CI sets the commit before a push to main), else
  `origin/<GITHUB_BASE_REF>` (a pull request's target, which CI fetches), else `origin/main`. If
  that ref can't be read (not fetched), the check warns and skips this comparison.

To opt a line out of both checks (an example URL, a literal that only looks like a key), put
`l10n-ignore` and the reason in a comment on that line or on a comment line just above it:

```swift
// l10n-ignore: an example address, not prose.
TextField(text: $model.address, prompt: Text(verbatim: "https://abs.example.com")) {
```

Placeholders are compared across locales as described under the conversion rules below: a
translation with a placeholder its English string lacks, or a malformed one, is skipped with a
warning; one that drops a placeholder (a string, or a plural's forms together) is kept with a
warning.

## Conversion rules

- Keys stay the legacy keys (`ButtonCancel`); every entry has `extractionState: manual`.
- `{0}`, `{1}`, … become positional specifiers `%1$@`, `%2$@`, …, so translations can
  reorder arguments. Pass every argument as a `String`.
- In strings with placeholders, a literal `%` becomes `%%`.
- `<strong>x</strong>` and `<b>x</b>` become `^[**x**]()`, Markdown bold inside an empty
  extended-attribute span; `<br>` becomes a newline. Plain `**x**` can't close when `x`
  ends in punctuation and a letter follows (`**重要提示！**此应用` renders literal
  asterisks); inside the brackets it always can. `L10n.attributed` parses with
  `allowsExtendedAttributes`.
  The importer warns about any other tag. Render it with `L10n.attributed`.
- Empty translations are skipped. So is a translation that uses a placeholder its English
  string doesn't have, or a malformed one such as `{0`; the importer prints a warning.
  Skipped keys get the English fill described below. A translation that drops a
  placeholder is kept, with a warning.
- Output is deterministic (sorted keys, Xcode's JSON layout), so rerunning is a no-op.

There are no plurals in the legacy strings; only native keys can be plurals (see above).
Pseudo-locale checks are out of scope for now; right-to-left rules are below.

## Right-to-left

Arabic (`ar`), Hebrew (`he`) and Persian (`fa`) run right to left. SwiftUI mirrors the
layout for them; these rules cover what it can't decide (Human Interface Guidelines,
[Right to left](https://developer.apple.com/design/human-interface-guidelines/right-to-left)).

- **Edges.** Use `.leading` and `.trailing`, never `.left` and `.right`, for alignment,
  padding, edges and transitions.
- **Symbols.** Use the `forward` and `backward` SF Symbols for navigation and direction
  (`chevron.forward`, `arrow.uturn.backward`, `rectangle.portrait.and.arrow.forward`):
  the system mirrors them, and not the `left` and `right` ones. Don't add
  `.flipsForRightToLeftLayoutDirection(true)` to an SF Symbol, which would flip a mirrored
  one back.
- **Media playback stays left to right.** Time doesn't flip, and the HIG says not to
  flip media playback controls, so:
  - `TransportControls` keeps jump back and previous chapter on the left, and
    `PlayerScrubber`, `PlayerTotalTrack` and the mini player's progress line fill from
    the left. Each sets `.environment(\.layoutDirection, .leftToRight)`, so a drag's x
    maps to time the same way in every language.
  - `gobackward`, `goforward`, `backward.end.fill` and `forward.end.fill` don't mirror,
    so the Control Center jump-back control matches the player.
  - The left arrow jumps back and the right arrow jumps forward (⌘← and ⌘→, with ⌥ for
    chapters).
  - Text inside those views is still localized. Only the layout direction is fixed.
- **Arrow keys.** By default SwiftUI swaps a `.keyboardShortcut`'s left and right arrows
  in right-to-left languages. Arrow-key shortcuts use `localization: .withoutMirroring`,
  and the handler maps the physical key: the player's seek keys, and the EPUB reader's
  page turns by the book's direction. `onKeyPress` and AppKit's `keyDown` report the
  physical key already (the comic and PDF readers).
- **Readers follow the book, the chrome follows the language.**
  - EPUB: epub.js lays pages out by the book's `page-progression-direction`. Each
    `relocated` event says whether that is right to left (`rightToLeft`). Then a tap
    near the left edge or the left arrow goes forward, as in the comic reader. The close
    button, the contents bar and the sheets follow the app's language.
  - Comics: the reader's right-to-left setting orders the pages. It defaults to
    `ComicInfo.xml`'s `<Manga>YesAndRightToLeft</Manga>` and can be changed per item. The pager is fixed left to right so an Arabic or Hebrew UI
    doesn't reverse them a second time.
  - PDF: PDFKit shows pages left to right. A PDF's `/Direction` viewer preference is not
    read yet.
- **Check by hand.** Run the app with `-AppleLanguages "(ar)"` and `"(he)"`, or use
  the Right-to-Left pseudolanguage in the scheme's options. `TransportControls` and
  `PlayerScrubber` have `Right to left` previews.
- **UI tests.** `LocalizedSmokeTests` signs in and opens an item in Arabic, German and a
  double-length right-to-left pseudolanguage, and attaches screenshots of each screen
  ([UI tests](testing/ui-tests.md#localized-runs-and-screenshots)).

## Missing translations

Keys a language hasn't translated in Weblate (or native keys nobody has translated) show
English. For every locale in the
catalog, the importer writes the English value with `state: "new"` for each key that is
missing, empty, or skipped, and real translations with `state: "translated"`. Xcode's
catalog editor therefore lists those strings as "new" (untranslated), and its
per-language progress stays accurate.

Without the fill, the compiled tables return the key name (`ButtonAllow`) for an
untranslated key: Foundation doesn't fall back to English per key, and the compiler
writes the key itself for missing format strings. `L10n.string` also falls back to the
English table if a lookup returns the key, as a safety net.

## Locale mapping

| File | Apple identifier |
| --- | --- |
| `en-us.json` | `en` (source language) |
| `no.json` | `nb` |
| `pt-br.json` | `pt-BR` |
| `vi-vn.json` | `vi` |
| `zh-cn.json` | `zh-Hans` |
| `zh_Hant.json` | `zh-Hant` |
| any other `<code>.json` | `<code>` |

Locales with no translated strings (currently `lv` and `uz`) produce no `.lproj` and are
not listed in `CFBundleLocalizations`.
