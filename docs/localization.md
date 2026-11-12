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
- **Hard-coded strings in `Audiobookshelf/Features/` fail.** A literal with a letter (outside its
  interpolations) passed straight to `Text`, `Text(verbatim:)`, `Button`, `Label`, `Toggle`,
  `Picker`, `Section`, `Menu`, `TextField`, `SecureField`, `Link`, `LabeledContent`,
  `ContentUnavailableView`, `ProgressView`, `GroupBox`, `DisclosureGroup`, `Tab`,
  `.navigationTitle`, `.navigationSubtitle`, `.accessibilityLabel`, `.accessibilityHint`,
  `.accessibilityValue`, `.help`, `.alert`, `.confirmationDialog`, or a `prompt:` argument is
  reported with `file:line`, unless it is a key. Symbols and numbers (`Text(verbatim: "•")`) pass.
  Only single-line literals on the call's line are seen.

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

There are no plurals in the legacy strings; only native keys can be plurals (see above). RTL and pseudo-locale checks are out of scope
for now.

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
