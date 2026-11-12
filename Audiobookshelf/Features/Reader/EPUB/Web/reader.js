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
  // How long the table of contents may take once the book is open; it comes from the archive
  // already in memory, so only a missing navigation document takes this long.
  const NAVIGATION_TIMEOUT_MS = 10000
  // The fonts the reader can override the book's with (ReaderSettings.FontFamily's raw values).
  const FONT_FAMILIES = ['serif', 'sans-serif']

  /** @type {any} */ let book = null
  /** @type {any} */ let rendition = null
  /** @type {any} */ let settings = null
  // Bumped by every `open`, so a superseded book's late callbacks post nothing.
  let generation = 0
  // Until the first display lands, relocations are epub.js settling on the start, not the reader.
  let displaying = false
  let lastRelocation = null
  // Displays a command is awaiting: their failures reach that command, not the `displayerror` post.
  let pendingDisplays = 0

  function post(event) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.absReader
    if (handler) handler.postMessage(event)
  }

  function postError(phase, error) {
    const message = (error && (error.message || String(error))) || 'Unknown error'
    post({ type: 'error', message: message, phase: phase })
  }

  function tocItems(items) {
    return (items || []).map(function (item) {
      return {
        id: String(item.id || ''),
        label: String(item.label || '').trim(),
        href: String(item.href || ''),
        subitems: tocItems(item.subitems)
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
    if (lastRelocation && lastRelocation.startCfi === event.startCfi && lastRelocation.progress === event.progress) {
      return
    }
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
    if (settings.fontFamily) rendition.themes.font(settings.fontFamily)
    else rendition.themes.removeOverride('font-family')
    const gap = columnGap(settings)
    rendition.settings.gap = gap
    if (rendition.manager) rendition.manager.settings.gap = gap
    rendition.spread(settings.spread === 'none' ? 'none' : 'auto', MIN_SPREAD_WIDTH)
  }

  function closeBook() {
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

  // Fails when the archive inflates past the limits, before epub.js inflates any of it.
  async function checkExpansion(data) {
    const zip = await window.JSZip.loadAsync(data)
    let total = 0
    for (const entry of Object.values(zip.files)) {
      if (entry.dir) continue
      total += await inflatedSize(entry, Math.min(MAX_ENTRY_BYTES, MAX_BOOK_BYTES - total))
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

  // Displays `target`. epub.js reports a section it can't render only as `displayerror` and leaves
  // `display`'s promise pending, so this settles on either.
  async function display(shown, target) {
    let onError
    const failed = new Promise(function (resolve, reject) {
      onError = reject
    })
    shown.on('displayerror', onError)
    pendingDisplays += 1
    try {
      return await Promise.race([shown.display(target), failed])
    } finally {
      pendingDisplays -= 1
      shown.off('displayerror', onError)
    }
  }

  async function open(command, context) {
    const url = String(command.url || '')
    if (url.indexOf(BOOK_URL_PREFIX) !== 0) throw new Error('Not a book URL')
    const opening = validSettings(command.settings)
    closeBook()
    settings = opening
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
      if (isCurrent() && pendingDisplays === 0) postError('display', error)
    })

    // epub.js never settles the table of contents when the book's navigation document is missing.
    // Tests shorten the deadline: WebKit throttles the timers of a page that isn't on screen.
    const navigationTimeout = Number(window.absReaderNavigationTimeoutMs) || NAVIGATION_TIMEOUT_MS
    withDeadline(opened.loaded.navigation, navigationTimeout, 'The table of contents did not load')
      .then(function (navigation) {
        if (isCurrent()) post({ type: 'toc', items: tocItems(navigation && navigation.toc) })
      })
      .catch(function (error) {
        if (isCurrent()) postError('toc', error)
      })

    try {
      // Not `ready`: that also waits for the table of contents.
      await Promise.race([opened.opened, failed])
    } catch (error) {
      throw Object.assign(asError(error), { phase: 'open' })
    }
    if (!isCurrent()) return

    let target
    if (command.location) {
      try {
        if (opened.spine.get(command.location)) target = command.location
      } catch (error) {
        target = undefined
      }
    }

    let locationsLoaded = false
    if (command.locations) {
      try {
        opened.locations.load(command.locations)
        locationsLoaded = opened.locations.length() > 0
      } catch (error) {
        locationsLoaded = false
      }
    }

    displaying = true
    try {
      // As the legacy reader does: the first display can land a page off, the second settles it.
      await display(shown, target)
      if (isCurrent()) await display(shown, target)
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
        return display(requireRendition(), String(command.target || ''))
      case 'next':
        return requireRendition().next()
      case 'prev':
        return requireRendition().prev()
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
