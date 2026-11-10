# Brand assets

The app icon, accent color, and logo are original artwork made for this project. They
are not the upstream Audiobookshelf logo (`static/Logo.png`). We chose a distinct mark
so the app is not confused with the official Audiobookshelf app on the App Store. The
owner can replace the artwork at any time; keep the file names below so no build
settings change.

## License

The artwork is licensed under the GNU General Public License v3.0, like the rest of the
repository (see [LICENSE](../LICENSE)).

## Mark

An open book with a sound wave rising from its spine: seven rounded bars, symmetric
around the center, above two white pages. All shapes are plain geometry (rounded
rectangles and cubic curves) on a 1024 × 1024 canvas.

## Colors

| Use | Light | Dark |
| --- | --- | --- |
| Icon background (top → bottom gradient) | `#127A80` → `#0B4A52` | `#163036` → `#070F12` |
| Icon wave | `#F5B83D` | `#F5B83D` |
| Icon book | `#FFFFFF` | `#FFFFFF` |
| `AccentColor` | `#0E7C86` | `#4FC3CC` |

The system derives the tinted and clear icon variants from the layers' luminance; the
icon defines only a dark background specialization.

## Files

| Path | What it is |
| --- | --- |
| `Audiobookshelf/AppIcon.icon/icon.json` | Icon Composer document: background gradient, groups, glass and shadow settings |
| `Audiobookshelf/AppIcon.icon/Assets/Wave.svg` | Front layer: the sound wave |
| `Audiobookshelf/AppIcon.icon/Assets/Book.svg` | Back layer: the open book |
| `Audiobookshelf/Assets.xcassets/AccentColor.colorset` | Global accent color (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`) |
| `Audiobookshelf/Assets.xcassets/Logo.imageset/Logo.svg` | Monochrome template logo for the UI, for example `Image("Logo")` |

The app target sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

## Editing

Open `Audiobookshelf/AppIcon.icon` in Icon Composer (in
`Xcode.app/Contents/Applications`), or edit the SVG layers and `icon.json` by hand.
Layer SVGs must stay 1024 × 1024. If you change a shape, update `Logo.svg` too; it
combines both layers in a single color.

To check the icon without building the app:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p /tmp/icon-check
xcrun actool Audiobookshelf/AppIcon.icon Audiobookshelf/Assets.xcassets \
  --compile /tmp/icon-check --platform iphoneos --minimum-deployment-target 27.0 \
  --target-device iphone --target-device ipad \
  --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist /tmp/icon-check/partial.plist \
  --output-format human-readable-text
```

Repeat with `--platform macosx` (without `--target-device`). To render a preview of a
variant (`Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`):

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Audiobookshelf/AppIcon.icon --export-preview iOS Dark 512 512 1 -45 /tmp/icon-dark.png
```
