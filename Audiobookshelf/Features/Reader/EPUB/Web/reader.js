// The bridge between the native reader and epub.js (see the EPUB bridge contract, ADR 0008).
//
// Swift calls `window.absReader.handle(command)` through `callAsyncJavaScript` and awaits the
// promise; failures also post an `error` event. Events go to Swift through the `absReader`
// message handler as plain JSON objects with a string `type`.
'use strict'
;(function () {
  const BOOK_URL_PREFIX = 'absreader://book/'
  const MIN_SPREAD_WIDTH = 800
  // What a book may inflate to (a zip bomb guard), per entry and in total. Every entry is inflated
  // once and its actual output counted, since a ZIP's size fields can lie.
  const MAX_ENTRY_BYTES = 64 * 1024 * 1024
  const MAX_BOOK_BYTES = 512 * 1024 * 1024
  // What the archive's directory may list, checked before JSZip reads it: entries, and the bytes of
  // names, extra fields and comments it decodes (a local name counts once per entry using it).
  const MAX_ENTRIES = 10000
  const MAX_METADATA_BYTES = 8 * 1024 * 1024
  // How long the table of contents may take once the book is open; it comes from the archive
  // already in memory, so only a missing navigation document takes this long.
  const NAVIGATION_TIMEOUT_MS = 10000
  // The fonts the reader can override the book's with (ReaderSettings.FontFamily's raw values).
  const FONT_FAMILIES = ['serif', 'sans-serif']
  // Where a section's own inline font is kept, since epub.js clears it with the reader's override.
  const BOOK_FONT = 'data-abs-book-font'

  /** @type {any} */ let book = null
  /** @type {any} */ let rendition = null
  /** @type {any} */ let settings = null
  // Bumped by every `open`, so a superseded book's late callbacks post nothing.
  let generation = 0
  // Until the first display lands, relocations are epub.js settling on the start, not the reader.
  let displaying = false
  let lastRelocation = null
  // The open book's own state: the displays a command is awaiting (their failures reach that
  // command, not the `displayerror` post), whether the reader's font is applied, and `closed`,
  // which rejects when the book is replaced so nothing awaiting it is stranded.
  /** @type {any} */ let session = null

  function newSession() {
    let close
    const closed = new Promise(function (resolve, reject) {
      close = function () {
        reject(new Error('The book was closed'))
      }
    })
    closed.catch(function () {})
    return { pendingDisplays: 0, fontApplied: false, closed: closed, close: close }
  }

  function post(event) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.absReader
    if (handler) handler.postMessage(event)
  }

  function postError(phase, error) {
    const message = (error && (error.message || String(error))) || 'Unknown error'
    post({ type: 'error', message: message, phase: phase })
  }

  // A navigation document's links are relative to it, but epub.js's spine (and `relocated`'s href)
  // to the package; this makes `href` relative to the package, given the document's `navPath`.
  function packageHref(href, navPath) {
    if (!navPath) return href
    try {
      const url = new URL(href, new URL(navPath, 'http://package/'))
      if (url.origin !== 'http://package') return href
      return decodeURI(url.pathname.slice(1)) + url.hash
    } catch (error) {
      return href
    }
  }

  function tocItems(items, navPath) {
    return (items || []).map(function (item) {
      return {
        id: String(item.id || ''),
        label: String(item.label || '').trim(),
        href: packageHref(String(item.href || ''), navPath),
        subitems: tocItems(item.subitems, navPath)
      }
    })
  }

  function postRelocated(location) {
    if (!location || !location.start || !location.end) return
    const event = {
      type: 'relocated',
      startCfi: location.start.cfi,
      endCfi: location.end.cfi,
      progress: Number(location.end.percentage) || 0,
      href: location.start.href || null,
      atStart: Boolean(location.atStart),
      atEnd: Boolean(location.atEnd)
    }
    const same = function (key) {
      return lastRelocation[key] === event[key]
    }
    if (lastRelocation && Object.keys(event).every(same)) return
    lastRelocation = event
    post(event)
  }

  function postCurrentLocation() {
    if (!rendition || displaying) return
    const location = rendition.currentLocation()
    // A promise while the view isn't laid out yet; a later `relocated` reports it.
    if (location && typeof location.then !== 'function') postRelocated(location)
  }

  function validSettings(next) {
    if (!next || typeof next !== 'object' || !next.themeRules || typeof next.themeRules !== 'object') {
      throw new Error('Invalid settings')
    }
    if (next.fontFamily !== undefined && FONT_FAMILIES.indexOf(next.fontFamily) === -1) {
      throw new Error('Invalid settings: fontFamily')
    }
    return next
  }

  // The column gap in CSS pixels (the Duo hinge), or `undefined` for epub.js's own (a twelfth of
  // the width): epub.js lays out with no gap at all for `0`.
  function columnGap(next) {
    const gap = Number(next.gap)
    return gap > 0 ? gap : undefined
  }

  function applySettings(next) {
    settings = validSettings(next)
    if (!rendition) return
    rendition.themes.register('abs', settings.themeRules)
    rendition.themes.select('abs')
    rendition.themes.fontSize((Number(settings.fontScale) || 100) + '%')
    // As the legacy reader does: the font overrides the book's own (`!important`).
    if (settings.fontFamily) {
      rendition.themes.font(settings.fontFamily)
      session.fontApplied = true
    } else if (session.fontApplied) {
      rendition.themes.removeOverride('font-family')
      restoreBookFonts(rendition)
      session.fontApplied = false
    }
    const gap = columnGap(settings)
    rendition.settings.gap = gap
    if (rendition.manager) rendition.manager.settings.gap = gap
    applySpread(rendition)
  }

  function applySpread(shown) {
    shown.spread(settings.spread === 'none' ? 'none' : 'auto', MIN_SPREAD_WIDTH)
  }

  // Keeps a section's inline font (a spine content hook, before epub.js applies any override).
  function keepBookFont(section) {
    const body = section.querySelector('body')
    const value = body && body.style && body.style.getPropertyValue('font-family')
    if (value) body.setAttribute(BOOK_FONT, value + '|' + body.style.getPropertyPriority('font-family'))
  }

  // epub.js's `removeOverride` deletes each section's inline font, its own included; put it back.
  function restoreBookFonts(shown) {
    shown.getContents().forEach(function (contents) {
      const kept = contents.content && contents.content.getAttribute(BOOK_FONT)
      if (!kept) return
      const split = kept.lastIndexOf('|')
      contents.content.style.setProperty('font-family', kept.slice(0, split), kept.slice(split + 1))
    })
  }

  function closeBook() {
    // Settle what's awaiting the old book first: epub.js's destroy can leave its displays pending.
    if (session) session.close()
    session = null
    if (book) book.destroy()
    book = null
    rendition = null
    lastRelocation = null
    displaying = false
  }

  // A tap's position as fractions of the reader's viewport. A tap on a link or one that ends a
  // selection is the book's, not a page turn or a toolbar toggle.
  function onClick(event) {
    const target = event.target
    if (target && typeof target.closest === 'function' && target.closest('a')) return
    const view = event.view
    const selection = view && view.getSelection && view.getSelection()
    if (selection && !selection.isCollapsed) return
    const frame = view && view.frameElement
    const offset = frame ? frame.getBoundingClientRect() : { left: 0, top: 0 }
    const clamp = function (value) {
      return Math.min(1, Math.max(0, value))
    }
    post({
      type: 'tap',
      x: clamp((offset.left + event.clientX) / window.innerWidth),
      y: clamp((offset.top + event.clientY) / window.innerHeight)
    })
  }

  // How many bytes `entry` inflates to, failing once that passes `limit`.
  function inflatedSize(entry, limit) {
    return new Promise(function (resolve, reject) {
      let size = 0
      let settled = false
      const stream = entry.internalStream('uint8array')
      stream
        .on('data', function (chunk) {
          if (settled) return
          size += chunk.length
          if (size <= limit) return
          settled = true
          stream.pause()
          reject(new Error('The book expands beyond what the reader can open'))
        })
        .on('error', function (error) {
          if (!settled) reject(error)
          settled = true
        })
        .on('end', function () {
          if (!settled) resolve(size)
          settled = true
        })
        .resume()
    })
  }

  // JSZip 3.10.1 trusts the archive's directory: a ZIP64 record with a negative length loops it
  // forever, and many entries can share one long local name. This walks the directory first,
  // bounded, and fails on anything out of bounds. Lengths read unsigned and every step moves on.
  function checkArchive(data) {
    const view = new DataView(data)
    const fail = function () {
      throw new Error('The book is not an archive the reader can open')
    }
    const u16 = function (at) {
      return view.getUint16(at, true)
    }
    const u32 = function (at) {
      return view.getUint32(at, true)
    }
    // The end record: 22 bytes, then a comment of up to 65,535; JSZip takes the last one.
    let end = view.byteLength - 22
    const earliest = Math.max(0, view.byteLength - 65557)
    while (end >= earliest && u32(end) !== 0x06054b50) end--
    if (end < earliest) fail()
    // All-ones fields mean ZIP64, which a book within the expansion limits never needs.
    for (const at of [4, 6, 8, 10]) if (u16(end + at) === 0xffff) fail()
    const start = u32(end + 16)
    if (u32(end + 12) === 0xffffffff || start === 0xffffffff || start + u32(end + 12) !== end) fail()

    let entries = 0
    let metadata = 0
    for (let at = start; at < end; entries++) {
      if (entries >= MAX_ENTRIES || at + 46 > end || u32(at) !== 0x02014b50) fail()
      const compressedSize = u32(at + 20)
      const name = u16(at + 28)
      const extra = u16(at + 30)
      const comment = u16(at + 32)
      const local = u32(at + 42)
      if ([compressedSize, u32(at + 24), local].indexOf(0xffffffff) !== -1 || u16(at + 34) === 0xffff) fail()
      const next = at + 46 + name + extra + comment
      if (next > end) fail()
      // Each extra field record must fit in the extra field.
      const extraEnd = at + 46 + name + extra
      for (let field = at + 46 + name; field + 4 <= extraEnd; field += 4 + u16(field + 2)) {
        if (field + 4 + u16(field + 2) > extraEnd) fail()
      }
      // The local header, its name and extra field, and the data must lie before the directory.
      if (local + 30 > start || u32(local) !== 0x04034b50) fail()
      const localName = u16(local + 26)
      const localExtra = u16(local + 28)
      if (local + 30 + localName + localExtra + compressedSize > start) fail()
      metadata += name + extra + comment + localName + localExtra
      if (metadata > MAX_METADATA_BYTES) fail()
      at = next
    }
  }

  // Fails when the archive inflates past the limits, before epub.js inflates any of it.
  async function checkExpansion(data) {
    checkArchive(data)
    const zip = await window.JSZip.loadAsync(data)
    let total = 0
    for (const entry of Object.values(zip.files)) {
      if (entry.dir) continue
      total += await inflatedSize(entry, Math.min(MAX_ENTRY_BYTES, MAX_BOOK_BYTES - total))
    }
  }

  // Every URL in `content` swapped for its replacement in one pass, longest first. epub.js swaps
  // each in turn over the whole text, so a later URL also matches inside the blob URLs an earlier
  // one put in, and the text grows exponentially with the assets a book lists.
  function substituteOnce(content, urls, replacements) {
    const swaps = new Map()
    urls.forEach(function (url, index) {
      if (url && replacements[index] && !swaps.has(url)) swaps.set(url, replacements[index])
    })
    if (swaps.size === 0) return content
    const pattern = Array.from(swaps.keys())
      .sort(function (a, b) {
        return b.length - a.length
      })
      .map(function (url) {
        return url.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&')
      })
      .join('|')
    return content.replace(new RegExp(pattern, 'g'), function (url) {
      return swaps.get(url)
    })
  }

  // Wraps the book's unpacking, which epub.js does once the package loads: refuses an asset listed
  // twice (epub.js copies each listing out of the archive at once, past the size limits), and
  // swaps epub.js's sections' and style sheets' URL substitution for `substituteOnce`. epub.js
  // drops an asset that failed to load from `replacementUrls`, shifting the later ones onto the
  // wrong URLs, so the replacements come from the archive's cache and the rewritten style sheets.
  function guardResources(opening) {
    const unpack = opening.unpack
    opening.unpack = function (packaging) {
      const assets = new Set()
      for (const item of Object.values(packaging.manifest || {})) {
        if (!item.href || item.type === 'application/xhtml+xml' || item.type === 'text/html') continue
        let path = this.resolve(item.href)
        try {
          path = decodeURIComponent(path)
        } catch (error) {}
        // epub.js reports any failure to open as "Cannot load book"; `open` says why.
        if (assets.has(path)) throw (this.refusal = new Error('The book lists a file more than once'))
        assets.add(path)
      }
      const unpacked = unpack.call(this, packaging)
      const resources = this.resources
      const sheets = new Map()
      const replacements = function () {
        return resources.urls.map(function (href) {
          return sheets.get(href) || resources.settings.archive.urlCache[resources.settings.resolver(href)]
        })
      }
      resources.substitute = function (content, url) {
        return substituteOnce(content, url ? this.relativeTo(url) : this.urls, replacements())
      }
      // As epub.js's own, which `replaceCss` calls once the assets' blob URLs exist.
      resources.createCssFile = function (href) {
        if (href.charAt(0) === '/') return Promise.resolve()
        const absolute = this.settings.resolver(href)
        const text = this.settings.archive.getText(absolute)
        if (!text) return Promise.resolve()
        return text.then(
          function (css) {
            const replaced = substituteOnce(css, this.relativeTo(absolute), replacements())
            const sheet = URL.createObjectURL(new Blob([replaced], { type: 'text/css' }))
            sheets.set(href, sheet)
            return sheet
          }.bind(this),
          function () {
            return undefined
          }
        )
      }
      return unpacked
    }
  }

  async function fetchBook(url) {
    const response = await fetch(url)
    if (!response.ok) throw new Error('The book could not be loaded (HTTP ' + response.status + ')')
    return response.arrayBuffer()
  }

  function withDeadline(promise, milliseconds, message) {
    let timer
    const deadline = new Promise(function (resolve, reject) {
      timer = setTimeout(function () {
        reject(new Error(message))
      }, milliseconds)
    })
    return Promise.race([promise, deadline]).finally(function () {
      clearTimeout(timer)
    })
  }

  // epub.js leaves a section that failed to display holding its queue, so `next` and `prev` would
  // wait for good; settling the failed display lets the queue move on.
  function releaseQueue(shown) {
    if (shown.displaying) shown.displaying.resolve()
  }

  // Displays `target`. epub.js reports a section it can't render only as `displayerror` and leaves
  // `display`'s promise pending, so this settles on either, or on the book being closed.
  async function display(current, shown, target) {
    let onError
    const failed = new Promise(function (resolve, reject) {
      onError = reject
    })
    shown.on('displayerror', onError)
    current.pendingDisplays += 1
    try {
      return await Promise.race([shown.display(target), failed, current.closed])
    } catch (error) {
      releaseQueue(shown)
      throw error
    } finally {
      current.pendingDisplays -= 1
      shown.off('displayerror', onError)
    }
  }

  // Locations cached by an earlier `locationsReady`: a JSON array of CFIs, or nothing usable.
  // epub.js's `load` keeps whatever parses, even `null`, and then can't display.
  function cachedLocations(value) {
    try {
      const parsed = JSON.parse(String(value))
      const valid = Array.isArray(parsed) && parsed.length > 0
      if (valid && parsed.every(function (cfi) { return typeof cfi === 'string' })) return parsed
    } catch (error) {
      return null
    }
    return null
  }

  async function open(command, context) {
    const url = String(command.url || '')
    if (url.indexOf(BOOK_URL_PREFIX) !== 0) throw new Error('Not a book URL')
    const opening = validSettings(command.settings)
    closeBook()
    settings = opening
    session = newSession()
    const state = session
    const current = ++generation
    context.generation = current
    const isCurrent = function () {
      return current === generation
    }

    let data
    try {
      data = await fetchBook(url)
      if (!isCurrent()) return
      await checkExpansion(data)
    } catch (error) {
      throw Object.assign(asError(error), { phase: 'open' })
    }
    if (!isCurrent()) return

    book = window.ePub(data, { openAs: 'binary' })
    guardResources(book)
    book.spine.hooks.content.register(keepBookFont)
    // A book that fails to load leaves `opened` pending for good; epub.js only says `openFailed`.
    const failed = new Promise(function (resolve, reject) {
      book.on('openFailed', reject)
    })
    rendition = book.renderTo('viewer', {
      width: '100%',
      height: '100%',
      spread: settings.spread === 'none' ? 'none' : 'auto',
      minSpreadWidth: MIN_SPREAD_WIDTH,
      allowScriptedContent: false,
      // The legacy app's and web client's layout (ADR 0008).
      flow: 'paginated',
      manager: 'continuous',
      snap: true,
      gap: columnGap(settings)
    })
    const opened = book
    const shown = rendition
    applySettings(settings)

    shown.on('displayed', function () {
      // From the legacy reader: epub.js's snapper misreads a fractional scrollLeft as off a page.
      const snapper = shown.manager && shown.manager.snapper
      if (!snapper) return
      snapper.needsSnap = function () {
        const left = Math.round(this.scrollLeft)
        const snapWidth = this.layout.pageWidth * this.layout.divisor
        return left % snapWidth !== 0
      }
    })
    shown.on('relocated', function (location) {
      if (isCurrent() && !displaying) postRelocated(location)
    })
    shown.on('click', function (event) {
      if (isCurrent()) onClick(event)
    })
    shown.on('displayerror', function (error) {
      // One of epub.js's own displays (a command's display reports its failure itself).
      if (!isCurrent() || state.pendingDisplays > 0) return
      releaseQueue(shown)
      postError('display', error)
    })

    // epub.js never settles the table of contents when the book's navigation document is missing.
    // Tests shorten the deadline: WebKit throttles the timers of a page that isn't on screen.
    const navigationTimeout = Number(window.absReaderNavigationTimeoutMs) || NAVIGATION_TIMEOUT_MS
    withDeadline(opened.loaded.navigation, navigationTimeout, 'The table of contents did not load')
      .then(function (navigation) {
        const packaging = opened.packaging || {}
        const navPath = packaging.navPath || packaging.ncxPath
        if (isCurrent()) post({ type: 'toc', items: tocItems(navigation && navigation.toc, navPath) })
      })
      .catch(function (error) {
        if (isCurrent()) postError('toc', error)
      })

    try {
      // Not `ready`: that also waits for the table of contents.
      await Promise.race([opened.opened, failed, state.closed])
      // epub.js's start takes the book's `rendition:spread` over ours; the reader's setting wins.
      await Promise.race([shown.started, failed, state.closed])
    } catch (error) {
      throw Object.assign(asError(opened.refusal || error), { phase: 'open' })
    }
    if (!isCurrent()) return
    applySpread(shown)

    let target
    if (command.location) {
      try {
        if (opened.spine.get(command.location)) target = command.location
      } catch (error) {
        target = undefined
      }
    }

    let locationsLoaded = false
    const cached = command.locations ? cachedLocations(command.locations) : null
    if (cached) {
      try {
        opened.locations.load(cached)
        locationsLoaded = opened.locations.length() > 0
      } catch (error) {
        locationsLoaded = false
      }
    }

    // epub.js reads the page list on every relocation but only sets it once navigation loads, which
    // a missing navigation document never does; a later load still replaces this empty one.
    if (!opened.pageList) {
      opened.pageList = {
        pages: [],
        locations: [],
        pageFromCfi: function () {
          return -1
        },
        destroy: function () {}
      }
    }

    displaying = true
    try {
      // As the legacy reader does: the first display can land a page off, the second settles it.
      await display(state, shown, target)
      if (isCurrent()) await display(state, shown, target)
    } catch (error) {
      throw Object.assign(asError(error), { phase: 'display' })
    } finally {
      if (isCurrent()) displaying = false
    }
    if (!isCurrent()) return
    postCurrentLocation()

    if (!locationsLoaded) {
      opened.locations
        .generate()
        .then(function () {
          if (!isCurrent()) return
          post({ type: 'locationsReady', locations: opened.locations.save() })
          // The percentage was 0 until the locations existed.
          postCurrentLocation()
        })
        .catch(function (error) {
          if (isCurrent()) postError('locations', error)
        })
    }
  }

  function asError(error) {
    return error instanceof Error ? error : new Error(String(error))
  }

  function requireRendition() {
    if (!rendition) throw new Error('No book is open')
    return rendition
  }

  async function run(command, context) {
    switch (command.type) {
      case 'open':
        return open(command, context)
      case 'display':
        return display(session, requireRendition(), String(command.target || ''))
      case 'next':
        return Promise.race([requireRendition().next(), session.closed])
      case 'prev':
        return Promise.race([requireRendition().prev(), session.closed])
      case 'applySettings':
        return applySettings(command.settings)
      default:
        throw new Error('Unknown command: ' + String(command.type))
    }
  }

  window.absReader = {
    /** Runs one command; resolves with nothing once it's done. */
    handle: async function (command) {
      if (!command || typeof command !== 'object') throw new Error('Invalid command')
      // The book this command belongs to; `open` moves it to the new one. A failure a later `open`
      // has superseded still rejects its command but posts nothing into the new book's events.
      const context = { generation: generation }
      try {
        await run(command, context)
      } catch (error) {
        const failure = asError(error)
        if (context.generation === generation) postError(failure.phase || String(command.type), failure)
        throw failure
      }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      post({ type: 'ready' })
    })
  } else {
    post({ type: 'ready' })
  }
})()
