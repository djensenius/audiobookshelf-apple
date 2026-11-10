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
| `mise run strings:check` | Fail if the catalog or the app's `CFBundleLocalizations` is out of date (runs in CI) |
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

The importer fails if a native key also exists in `strings/`; pick another key. Native
keys nobody has translated get the English fill like any other key.

Translations arrive through the upstream sync ([upstream-sync.md](upstream-sync.md)), not
through Weblate commits to this repository; rerun `mise run strings` after syncing
`strings/`. If upstream adds a locale, the importer either maps it or fails with a message
asking for an entry in `LocaleMapping.overrides`; then add the new identifier to
`CFBundleLocalizations` in `Audiobookshelf/Info.plist` (`strings:check` prints the list).

## Using strings in Swift

- `L10n.string` returns plain text. `L10n.attributed` renders the localized value's inline
  Markdown (bold, line breaks kept) and inserts the arguments as plain text.
- Never run Markdown over formatted output (`AttributedString(markdown: L10n.string(…))`
  or `Text(LocalizedStringKey(…))`): arguments are often server data such as user names or
  titles, and would be parsed as links or formatting.
- In ABSUI, look strings up only through `L10n` (which always uses `bundle: .module`) and
  use `Text(verbatim:)` for literals that aren't localized. A `Text("…")` literal or
  `String(localized:)` call in ABSUI would let Xcode's string extraction add entries to
  the catalog, which then fails `strings:check`.

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

There are no plurals in the legacy strings. RTL and pseudo-locale checks are out of scope
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
