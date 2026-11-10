# Localization

The flat JSON files in `strings/` stay the source of truth. Translators edit them in
Weblate, as they did for the Capacitor app, and `mise run strings` generates the String
Catalog the native app uses:

```
strings/*.json  ──mise run strings──▶  Packages/AudiobookshelfKit/Sources/ABSUI/Resources/Localizable.xcstrings
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

## Adding or changing a string

1. Add the key and English text to `strings/en-us.json`, keeping keys sorted and using
   the legacy conventions (`Button…`, `Header…`, `Label…`, `Message…`; `{0}` placeholders;
   `<strong>` for emphasis) so the file stays compatible with upstream and Weblate.
2. Run `mise run strings` and commit both files.
3. Use the key from Swift: `L10n.string("ButtonCancel")` or
   `L10n.string("LabelByAuthor", author)`.

Translations arrive through Weblate commits to `strings/*.json`; rerun `mise run strings`
after merging them. If Weblate adds a locale, the importer either maps it or fails with a
message asking for an entry in `LocaleMapping.overrides`; then add the new identifier to
`CFBundleLocalizations` in `Audiobookshelf/Info.plist` (`strings:check` prints the list).

## Conversion rules

- Keys stay the legacy keys (`ButtonCancel`); every entry has `extractionState: manual`.
- `{0}`, `{1}`, … become positional specifiers `%1$@`, `%2$@`, …, so translations can
  reorder arguments. Pass every argument as a `String`.
- In strings with placeholders, a literal `%` becomes `%%`.
- `<strong>x</strong>` and `<b>x</b>` become Markdown `**x**`; `<br>` becomes a newline.
  The importer warns about any other tag. Render Markdown with
  `AttributedString(markdown:)`.
- Empty translations are skipped. So is a translation that uses a placeholder its English
  string doesn't have, or a malformed one such as `{0`; the importer prints a warning.
- Output is deterministic (sorted keys, Xcode's JSON layout), so rerunning is a no-op.

There are no plurals in the legacy strings. RTL and pseudo-locale checks are out of scope
for now.

## Missing translations

A key a language hasn't translated is not written to that language. At runtime the
compiled tables return the key itself for it (Foundation doesn't fall back to English per
key), so always look strings up through `L10n.string`, which falls back to English.

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
