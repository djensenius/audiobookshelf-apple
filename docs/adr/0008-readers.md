# 0008. Ebook reader engines (EPUB, MOBI/AZW3, PDF, comics)

- Status: Accepted
- Date: 2026-11-09
- Issue: #100 (P6-10)

## Context

The native app has to open the ebook formats that Audiobookshelf serves. The server's
`SupportedEbookTypes` are `epub`, `pdf`, `mobi`, `azw3`, `cbr` and `cbz`. Each
format needs a rendering engine on iOS, iPadOS, iPhone Duo and **native macOS (not
Catalyst)**. Reading position must sync with the Audiobookshelf web reader through
`PATCH /api/me/progress/:id` using `{ ebookLocation, ebookProgress }`.

The legacy app ([`components/readers/`](../../components/readers)) and the web client
(`advplyr/audiobookshelf`, `client/components/readers/`, read on 2026-11-09, latest
release v2.37.2) use the same readers:

| Format | Legacy app and web client | `ebookLocation` written |
| --- | --- | --- |
| EPUB | epub.js (`epubjs` 0.3.88 in the [legacy `package.json`](../../package.json); 0.3.93 in the web client lockfile). Uses `flow: 'paginated'`, `manager: 'continuous'` and `spread: 'auto'` | `location.start.cfi`, e.g. `epubcfi(/6/6!/4/40[c3p19]/1:747)`. Readers ignore any saved value that doesn't start with `epubcfi` |
| MOBI/AZW3 | `assets/ebooks/mobi.js` ("borrowed from koodo-reader"), rendered as one long scrolling HTML iframe | **None.** Neither the legacy app nor the web client saves MOBI progress |
| PDF | `@teckel/vue-pdf` (pdf.js) | 1-based page number. The web client sends a number and the legacy app sends `String(page)` |
| CBZ/CBR | `libarchive.js` (WASM) | 1-based page number. Pages are images (`.jpeg .jpg .png .webp`) sorted by the **last number in the basename**, with unnumbered images appended |

The server stores `ebookLocation` as a `STRING` and `ebookProgress` as a `FLOAT`
(`server/models/MediaProgress.js`). The server has no ebook conversion or per-page
endpoint. It serves only the whole file through `GET /api/items/:id/ebook/:fileid?`.
It decodes CBR (`node-unrar-js`) only to extract comic metadata and covers.

Apple frameworks have no EPUB, MOBI or comic-archive engine. PDFKit covers PDF on
both platforms. There is no public ZIP API either, which is why ZIPFoundation is
already approved for CBZ (see [`docs/research/platform-apis.md` §7](../research/platform-apis.md)).
The SDK has no public libarchive or RAR API.

This repository is GPL-3.0 ([`LICENSE`](../../LICENSE)).

## Decision drivers

1. **Progress interoperability.** EPUB `ebookLocation` must be an epub.js-compatible
   CFI that the web reader can open, and the app must accept the CFIs the web reader
   writes. PDF and comic locations must be the same 1-based page numbers.
2. **One engine for iOS, iPadOS, Duo and native macOS.** Catalyst-only libraries are
   not acceptable.
3. **Swift 6 strict concurrency, built-in frameworks first.** Add SPM dependencies
   only when necessary.
4. **License compatibility with GPL-3.0** and App Store distribution.
5. **Dependency weight and maintenance risk.**
6. **Reader UX parity with the legacy app.** That means themes (black, dark, light),
   font, font size, line spacing, a table of contents, page turns, and two-page
   spreads on wide layouts.

## Options considered

Comparison matrix for the EPUB engine. Spike results are marked ✅/❌ (measured).
Everything else comes from the repositories' metadata.

| | Readium swift-toolkit 3.11.1 | WKWebView + epub.js 0.3.93 | WKWebView + foliate-js | Native-only (own parser + WKWebView/TextKit) |
| --- | --- | --- | --- | --- |
| License | BSD-3-Clause | BSD-2-Clause (JSZip: MIT or GPLv3) | MIT | n/a |
| Native macOS | ❌ `swift build` fails: `unable to resolve module dependency: 'UIKit'` (40 source files import UIKit, 0 have AppKit paths) | ✅ ran the spike on macOS 27.2 | Same WebKit path as epub.js (not spiked) | ✅ (to be written) |
| iOS | ✅ builds for the iOS Simulator and for generic iOS Release | ✅ bridge code typechecks for the iOS 27 Simulator | Not spiked | ✅ |
| Swift 6 | The 3.11.1 release is `swift-tools-version:5.10`, so its modules build in Swift 5 mode (60 `-swift-version 5` compiles vs 12 `-swift-version 6`). A Swift 6 consumer target built with 0 warnings. `develop` uses tools 6.2 and approachable concurrency (PR #852), shipping in 4.0 alphas | Our Swift code only. The spike compiled with `-swift-version 6` and no diagnostics | Our Swift code only | Our Swift code only |
| EPUB CFI | ❌ **Not supported, "no plan"** (issues #64 and #467). Uses its own `Locator` | ✅ same library and version as the web client | Has its own `epubcfi.js` (spec CFI). Its paginator "has no concept of CFIs", so exact parity with epub.js is unverified | Would need our own CFI generator and resolver |
| Weight | 12 modules (CryptoSwift, SwiftSoup, DifferenceKit, Fuzi, `marmelroy/Zip`, Readium's own ZIPFoundation fork plus Minizip). ~20 MB of unstripped arm64 Release `.o` files and ~1 MB of resources | `epub.min.js` 224 KB + `jszip.min.js` 98 KB, vendored | ~7 MB repo, modules loaded on demand | Largest effort |
| Maintenance | Active: 3.10 (2026-06), 3.11 (2026-07), 3.11.1 (2026-10-16), 4.0.0-alpha.2 (2026-09). 55 open issues | Last stable 0.3.93 (2022-02), 0.5 alphas (2023). Last push 2026-03. 516 open issues | No releases; README says "*not* stable… API to change at any time". Last push 2026-05 | Ours |
| MOBI/AZW3 | No | No | Yes (`mobi.js`: MOBI + KF8) | No |

### Option 1: Readium swift-toolkit (SPM)

- Pros
  - Mature, native navigator with good accessibility, fixed layout, LCP DRM, TTS and
    search. Actively maintained with frequent releases.
  - BSD-3-Clause. Distributed through SPM. A Swift 6 consumer target builds cleanly.
- Cons
  - **iOS only.** The `Package.swift` declares only `.iOS("15.0")` and links UIKit. It
    does not build for native macOS. The cross-platform `EPUBView` proposal (#806) was
    closed with no macOS code on `develop`. We would need a second engine for Mac.
  - **No EPUB CFI support, and the maintainers have no plans to add it.** To
    interoperate with `ebookLocation` we would have to write and maintain a
    CFI ↔ `Locator` translator that matches epub.js page-start snapping.
  - Heavy transitive graph. It pulls a second ZIP library (Readium's ZIPFoundation
    fork alongside the approved upstream one), plus the stale `marmelroy/Zip` and
    CryptoSwift. Released versions still compile in Swift 5 mode, and Swift 6 lands
    in 4.0, which is still alpha.

### Option 2: WKWebView + vendored epub.js (the legacy approach)

- Pros
  - **CFI parity by construction.** We would use the same library, version (0.3.93)
    and API (`rendition.currentLocation().start.cfi`, `location.end.percentage`) as
    the web client.
  - WebKit is built in. One HTML/JS bundle serves iOS, iPadOS, Duo and native macOS.
    The Swift side is a small `WKURLSchemeHandler` plus a `WKScriptMessageHandler`.
  - Small (~320 KB of JS). Permissive licenses. No SPM dependency.
  - We can port the legacy behaviour directly: theme rules, `spread`, the TOC and the
    location cache.
- Cons
  - epub.js is effectively in maintenance mode, with no stable release since 2022. We
    own any fixes (vendored, pinned).
  - WebKit pauses `requestAnimationFrame` (which drives epub.js's queue) when the view
    is not composited. Rendering needs an on-screen, hosted view. Headless tests need
    a host app or a rAF shim.
  - Rendering is web-based. Accessibility and text selection come from WebKit, not
    native text.
  - CFIs snap to the start of the visible page. A position saved at one viewport size
    reopens at the start of the page that contains it at another size. This is
    identical to legacy app ↔ web behaviour today.

### Option 3: WKWebView + foliate-js

- Pros
  - MIT. Modern and modular. One library for EPUB, MOBI/KF8 (AZW3), FB2 and CBZ.
  - Has a spec-based CFI implementation and loads resources on demand.
- Cons
  - Explicitly unstable, with no releases. The README recommends a git submodule.
  - CFIs come from a different paginator than epub.js. Whether they are exactly
    compatible with the web client's stored values is unverified, so it would need
    its own round-trip test suite.
  - KF8 needs an extra decompressor (`fflate`) for fonts.

### Option 4: Native-only (own EPUB parser and layout)

- Pros
  - No JavaScript. Full control over layout, accessibility and theming.
- Cons
  - We would have to write an EPUB parser, CSS pagination and a CFI
    generator/resolver compatible with epub.js. That is far beyond the size of the
    readers epic, for no user-visible gain.

### Option 5: MOBI/AZW3 policy

The choices are to (a) keep the legacy `mobi.js` iframe, (b) adopt foliate-js
`mobi.js`, or (c) drop in-app rendering.

- Pros of dropping (c)
  - No progress interoperability to protect, because neither client stores MOBI
    progress.
  - Avoids porting legacy `mobi.js`, whose header credits koodo-reader. Koodo-reader
    is AGPL-3.0 today and the snippet's licence provenance is unclear. Also avoids an
    unstable second JS engine.
  - The legacy reader is weak: one unpaginated scroll, no TOC, no themes, no progress.
- Cons of dropping (c)
  - It is a parity regression for MOBI/AZW3-only items. Users must use the share sheet
    ("Open in…"), the server's send-to-device email feature, or the web reader.
  - Option (b) would restore MOBI in the same WKWebView later, at the cost of the
    stability concerns in Option 3.

### Option 6: CBR policy

The choices are to (a) drop CBR, (b) convert on the server, or (c) add a RAR
dependency.

- Pros of dropping (a)
  - No new dependency. CBZ (ZIPFoundation, already approved) covers the common case.
- Cons of dropping (a)
  - CBR-only libraries lose in-app reading.
- (b) Server-side conversion
  - The server has no such endpoint. It would need an upstream feature we don't
    control, so it is not viable now.
- (c) Dependencies
  - RARLAB `unrar` source (used by UnrarKit, last push 2023-10) has a non-OSI licence
    that is generally treated as GPL-incompatible. That rules it out for a GPL-3.0
    app.
  - libarchive has a BSD-licensed, clean-room RAR4/RAR5 reader. The SDK's
    `libarchive.tbd` is private (no headers), so we would have to vendor and build a
    C library. That is justified only if users ask for it.

## Decision

1. **EPUB: WKWebView + vendored epub.js 0.3.93 + JSZip 3.10.x (Option 2).** Pin the
   version to the web client's lockfile, not the legacy 0.3.88. Ship the minified
   files with their licence texts in the app bundle and in third-party notices.
   - **Bridge**
     - A `WKURLSchemeHandler` on a private scheme serves the reader page, the
       scripts, and the book bytes. Bytes come from the downloaded file or from an
       authenticated native `URLSession` fetch, so tokens never enter JavaScript.
     - JS → Swift events go through one `WKScriptMessageHandler` (`relocated`, `toc`,
       `tap`, `error`). Swift → JS calls use `callAsyncJavaScript` (`open`,
       `display(cfiOrHref)`, `next`, `prev`, `applySettings`).
   - **Progress**
     - Write `ebookLocation = location.start.cfi` and
       `ebookProgress = location.end.percentage`.
     - On open, accept `ebookLocation` only if it starts with `epubcfi` and
       `book.spine.get(cfi)` resolves it. Otherwise open at the start. This is the
       same rule as the web client.
     - Generate locations with epub.js's default (`generate()`, 150 chars) to match
       the web client's percentages. The legacy app used 100.
     - Cache the generated locations per item on disk instead of in `localStorage`.
2. **PDF: PDFKit** (`PDFView`) on all platforms. `ebookLocation` is the 1-based page
   number as a string (PDFKit's index + 1). Parse both numeric and string values.
3. **CBZ: native SwiftUI pager plus ZIPFoundation**, reading entries on demand.
   - Use the web client's page ordering exactly: accepted extensions, sort by the last
     number in the basename, unnumbered images last. Otherwise page numbers won't
     interoperate.
   - `ebookLocation` is the 1-based page number. Parse the optional `ComicInfo.xml`
     as the legacy app does.
4. **CBR: dropped from in-app reading for v1.** Show a "This format can't be opened
   in the app" state with "Open in…" and "Read in browser" actions. Revisit with a
   vendored libarchive (BSD) only if users ask for it. Never use RARLAB `unrar`.
5. **MOBI/AZW3: dropped from in-app reading for v1.** Use the same unsupported state
   plus the server's send-to-device action (P6-11c #103). Follow-up: evaluate
   foliate-js `mobi.js` inside the epub.js WKWebView host. Do not port the legacy
   koodo-derived `mobi.js`.
6. **Theming.** Use the legacy setting set: theme `black`/`dark`/`light`, font
   `serif`/`sans-serif`, font scale, line spacing, text stroke and spread
   `auto`/`none`.
   - Add `sepia` (P6-12 #104 scope) and a "match system" default for the theme.
   - EPUB applies these as epub.js theme rules (the legacy `themeRules`). PDF and
     comics only change the chrome and page background.
7. **Two-page spreads**
   - EPUB uses epub.js `spread: 'auto'`, which shows two columns when the content
     width is at least `minSpreadWidth`, 800 pt. That covers iPad landscape and wide
     Mac windows. `none` forces a single page.
   - On iPhone Duo spanned across the hinge, use a spread whose column gap equals the
     hinge reserved region (`GeometryProxy.reservedRegions`), so no text falls in the
     fold. Folded or single-panel layouts use a single page.
   - PDF uses `PDFView.displayMode = .twoUp` with `displaysAsBook` under the same
     width rule.
   - **Comics** show a two-page spread on wide layouts and a single page otherwise.
     This is new compared with the legacy app, which was single-page only. It is in
     the P6-13 #105 scope.
     - **When to show a spread:** the reader uses the shared `spread` setting
       (`auto`/`none`) in reader settings. `none` always shows a single page.
       With `auto`, the decision is split by platform:
       - **iOS and iPadOS:** show two pages when the horizontal size class is
         `.regular` and the reader area, measured with `onGeometryChange`, is
         wider than it is tall. This covers iPad landscape, including large Split
         View panes.
       - **iPhone Duo spanned across the hinge:** show two pages, one on each side
         of the hinge reserved region (`GeometryProxy.reservedRegions`). This
         applies even if the size class reports compact.
       - **macOS:** size classes don't describe the window, so decide from the
         reader's measured size. Show two pages when the width is at least 800 pt
         (the same threshold as epub.js `minSpreadWidth`) and the width is greater
         than the height. Re-evaluate as the window resizes.
       - **Single page:** iPhone, iPad portrait, narrow Mac windows and a folded
         Duo show one page.
     - **Pairing:** page 1 (the cover) is shown alone, then pages pair as (2, 3),
       (4, 5), and so on. These pages are also shown alone:
       - pages marked `DoublePage="True"` or `Type="FrontCover"` in
         `ComicInfo.xml`;
       - landscape images (wider than tall), which are usually pre-joined
         spreads;
       - a final odd page.

       After a page shown alone, pairing restarts from the next page.
     - **Reading direction:** a right-to-left toggle in reader settings, saved per
       item. RTL puts the lower-numbered page on the right and reverses swipe and
       arrow-key direction. The default is RTL when `ComicInfo.xml` has
       `<Manga>YesAndRightToLeft</Manga>`, and LTR otherwise.
     - **Location:** `ebookLocation` is the lower page number of the visible spread,
       so the web client's single-page reader reopens on the first page of that
       spread. `ebookProgress` uses the web formula `(page - 1) / numPages`.
     - **Vertical scroll mode** is always single-column.
8. **Code placement.** This follows [`docs/architecture.md`](../architecture.md) and
   ADR 0001. No new module is added.
   - **Views** live in the app target under `Audiobookshelf/Features/Reader/`. That
     covers `ReaderContainer` (P6-11a #101), `PDFReaderView` (P6-11b #102),
     `EPUBReaderView` with its `WKWebView` wrapper, scheme handler and
     `@MainActor` message handler (P6-12 #104), and `ComicReaderView` (P6-13 #105).
   - **Logic** lives in `ABSAppModel/Reader/`, so `swift test` covers it without
     WebKit:
     - `EbookProgressModel` and the format router (P6-11a #101);
     - `ebookLocation` parsing and validation (`epubcfi` prefix, 1-based page
       numbers sent as a number or a string);
     - the `ComicArchive` actor and the web-compatible page ordering (P6-13 #105).
       This replaces P6-13's "ABSUI or a reader module" wording, because `ABSUI`
       is for shared components and a new module would need its own ADR.
   - **Bundled JS** lives in `Audiobookshelf/Features/Reader/EPUB/Web/`. It holds the
     reader page and bridge script, `epub.min.js` 0.3.93 and `jszip.min.js` 3.10.x,
     unmodified. Each upstream licence file sits next to its script
     (`LICENSE-epubjs`, `LICENSE-jszip`). The synchronized folder copies them into
     the app bundle.
   - **Licence notices.** P6-12 #104 must add a repo-root `THIRD_PARTY_NOTICES.md`
     that lists:
     - epub.js: BSD-2-Clause, © FuturePress.
     - JSZip: dual-licensed MIT or GPLv3. We use it under MIT.

     P6-13 #105 adds the ZIPFoundation (MIT) entry.
   - **SPM dependencies.** ZIPFoundation, pinned for CBZ in P6-13 #105, remains the
     only approved package. EPUB and PDF add none.

Readium remains the fallback if epub.js becomes unworkable, but only together with a
macOS story and a CFI translator. Re-evaluate when Readium ships AppKit support.

**Sign-off.** The coordinator accepted the engine (WKWebView + epub.js 0.3.93) and
the v1 policy that CBR and MOBI/AZW3 are unsupported in the app. Merging this ADR is
the acceptance. The owner can supersede it with a new ADR.

## Consequences

- No new SPM dependency for EPUB or PDF. ZIPFoundation, already approved, is the only
  package and is used only for CBZ.
- We take on maintenance of a vendored, pinned epub.js. Upgrades must track the web
  client's version and rerun the CFI round-trip tests.
- Reader UI is SwiftUI chrome around a `WKWebView` (EPUB), a `PDFView` (PDF) or a
  native image pager (CBZ). This needs one platform wrapper each for UIKit and AppKit.
- WebKit rendering must be on screen to progress, because offscreen WebKit pauses
  `requestAnimationFrame`, which drives epub.js's render queue.
  `WKPreferences.inactiveSchedulingPolicy = .none` did not help offscreen.
  - Reader UI tests must run in a **hosted app** with the reader on screen, not in a
    bare `WKWebView`.
  - Package tests cover only the pure logic in `ABSAppModel/Reader/`.
  - Never ship the `setTimeout` rAF shim used in the spike.
- MOBI/AZW3 and CBR users lose in-app reading compared with the legacy app. Release
  notes must say so, and the item page must show the unsupported state instead of a
  broken reader.
- `THIRD_PARTY_NOTICES.md` must include epub.js (BSD-2-Clause) and JSZip (MIT or
  GPLv3, used under MIT) from P6-12 #104, and ZIPFoundation (MIT) from P6-13 #105.
- macOS sandbox: the reader needs only the existing network-client entitlement, and
  custom-scheme loading needs no extra entitlement.

## Validation

The throwaway spike ran outside the repository in `/tmp/abs-spike-epub` (now
deleted) with Xcode 27.2 and Swift 6.4.2 on macOS 27.2.

| Check | Result |
| --- | --- |
| Readium 3.11.1, native macOS `swift build` (consumer target `.macOS("27.0")`) | ❌ `CoverService.swift:8:8 unable to resolve module dependency: 'UIKit'` |
| Readium 3.11.1, `xcodebuild` for the iOS Simulator (Debug) and generic iOS (Release), Swift 6 consumer target | ✅ `BUILD SUCCEEDED`, 0 warnings. Readium modules compiled with `-swift-version 5` |
| Readium release weight | 12 modules. Unstripped arm64 Release object files total 20 MB. The largest are `ReadiumShared` 5.9 MB, `SwiftSoup` 5.4 MB and `ReadiumNavigator` 4.4 MB. Resources are about 1 MB |
| epub.js 0.3.93 + JSZip 3.10.2 in a `WKWebView` on **native macOS** (Swift 6 harness: `WKURLSchemeHandler` serving page, scripts and `.epub`; `WKScriptMessageHandler` bridge; `dark` theme registered) | ✅ Opened the book and displayed CFIs. The bridge returned `start`/`end` CFIs, spine index and href |
| CFI round trip: open at CFI → read `start.cfi` → open a **fresh** `Book` at that CFI → compare | ✅ 3/3 PASS. `epubcfi(/6/4!/4/2/1:0)` → same. `epubcfi(/6/6[c3]!/4/42[c3p20]/1:0)` → `epubcfi(/6/6!/4/40[c3p19]/1:747)` (page-start snap) → stable. `epubcfi(/6/2[c1]!/4/80[c1p39]/1:120)` → `epubcfi(/6/2!/4/80[c1p39]/1:0)` → stable |
| The same bridge code compiled for iOS (`swiftc -swift-version 6 -target arm64-apple-ios27.0-simulator -typecheck`) | ✅ no diagnostics |
| WebKit scheduling | `requestAnimationFrame` never fired for an offscreen or unattended window, even with `inactiveSchedulingPolicy = .none`. The harness used a `setTimeout` rAF shim (test-only) |

**Runtime validation moved to the implementing issues.** These checks could not be
run in the spike. They are acceptance criteria of the issues below:

| Check | Performed in |
| --- | --- |
| Live web-client CFI round trip with a real server and EPUB: save in the web reader, open in the app, save in the app, reopen in the web reader. Run on iOS and macOS | **performed in #104** (P6-12) |
| In-app run of the epub.js reader on iOS (the spike only typechecked the iOS bridge) and on macOS, inside the reader container from #101 (P6-11a) | **performed in #104** (P6-12) |
| EPUB two-page spread on iPad, Mac, and Duo spanned with a hinge-width gap (`minSpreadWidth`, reserved regions) | **performed in #104** (P6-12) |
| PDFKit two-up (`.twoUp`, `displaysAsBook`) on wide layouts, and the 1-based page `ebookLocation` round trip with the web client | **performed in #102** (P6-11b) |
| CBZ page ordering identical to the web client (last number in the basename, unnumbered images last), with fixture tests | **performed in #105** (P6-13) |
| Comic spread pairing tests: cover, double-page and landscape pages shown alone; RTL order; `ebookLocation` = lower page. Also a manual check on iPad landscape, Mac and spanned Duo | **performed in #105** (P6-13) |

**Assumed, not verified:**

- libarchive's RAR licence status. It comes from libarchive's documentation and
  knowledge, not a code audit. It is relevant only if CBR is revisited.

## References

- Legacy readers: [`components/readers/Reader.vue`](../../components/readers/Reader.vue),
  [`EpubReader.vue`](../../components/readers/EpubReader.vue),
  [`MobiReader.vue`](../../components/readers/MobiReader.vue),
  [`ComicReader.vue`](../../components/readers/ComicReader.vue),
  [`PdfReader.vue`](../../components/readers/PdfReader.vue),
  [`assets/ebooks/mobi.js`](../../assets/ebooks/mobi.js), and
  [`package.json`](../../package.json).
- Platform research: [`docs/research/platform-apis.md` §7 Zip / CBZ extraction](../research/platform-apis.md).
- Audiobookshelf web client and server (read-only):
  [`client/components/readers/`](https://github.com/advplyr/audiobookshelf/tree/master/client/components/readers),
  [`server/models/MediaProgress.js`](https://github.com/advplyr/audiobookshelf/blob/master/server/models/MediaProgress.js),
  [`server/utils/comicBookExtractors.js`](https://github.com/advplyr/audiobookshelf/blob/master/server/utils/comicBookExtractors.js), and
  [`server/utils/globals.js`](https://github.com/advplyr/audiobookshelf/blob/master/server/utils/globals.js).
- Readium: [swift-toolkit](https://github.com/readium/swift-toolkit) (`Package.swift`,
  README "Minimum Requirements"), and issues
  [#64](https://github.com/readium/swift-toolkit/issues/64),
  [#467](https://github.com/readium/swift-toolkit/issues/467) (no CFI),
  [#806](https://github.com/readium/swift-toolkit/issues/806) (cross-platform proposal) and
  [#852](https://github.com/readium/swift-toolkit/pull/852) (Swift 6.2 concurrency).
- [futurepress/epub.js](https://github.com/futurepress/epub.js) and
  [epubjs on npm](https://www.npmjs.com/package/epubjs) (0.3.93, BSD-2-Clause), plus
  [Stuk/jszip](https://github.com/Stuk/jszip).
- [johnfactotum/foliate-js](https://github.com/johnfactotum/foliate-js).
- [libarchive](https://github.com/libarchive/libarchive) and
  [abbeycode/UnrarKit](https://github.com/abbeycode/UnrarKit).
- [EPUB Canonical Fragment Identifiers 1.1](https://idpf.org/epub/linking/cfi/epub-cfi.html).
