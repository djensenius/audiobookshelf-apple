// The bridge between the native reader and epub.js (see the EPUB bridge contract, ADR 0008).
//
// Swift calls `window.absReader.handle(command)` through `callAsyncJavaScript` and awaits the
// promise; failures also post an `error` event. Events go to Swift through the `absReader`
// message handler as plain JSON objects with a string `type`.
'use strict'
;(function () {
  const BOOK_URL_PREFIX = 'absreader://book/'
  const MIN_SPREAD_WIDTH = 800

  /** @type {any} */ let book = null
  /** @type {any} */ let rendition = null
  /** @type {any} */ let settings = null
  // Bumped by every `open`, so a superseded book's late callbacks post nothing.
  let generation = 0
  // Until the first display lands, relocations are epub.js settling on the start, not the reader.
  let displaying = false
  let lastRelocation = null

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

  async function open(command) {
    const url = String(command.url || '')
    if (url.indexOf(BOOK_URL_PREFIX) !== 0) throw new Error('Not a book URL')
    const opening = validSettings(command.settings)
    closeBook()
    settings = opening
    const current = ++generation
    const isCurrent = function () {
      return current === generation
    }

    book = window.ePub(url, { openAs: 'epub' })
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
    shown.on('displayError', function (error) {
      if (isCurrent()) postError('display', error)
    })

    opened.loaded.navigation
      .then(function (navigation) {
        if (isCurrent()) post({ type: 'toc', items: tocItems(navigation && navigation.toc) })
      })
      .catch(function (error) {
        if (isCurrent()) postError('toc', error)
      })

    try {
      // A book that fails to load leaves `ready` pending for good; epub.js only says `openFailed`.
      await Promise.race([
        opened.ready,
        new Promise(function (resolve, reject) {
          opened.on('openFailed', reject)
        })
      ])
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
      await shown.display(target)
      if (isCurrent()) await shown.display(target)
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

  async function run(command) {
    switch (command.type) {
      case 'open':
        return open(command)
      case 'display':
        return requireRendition().display(String(command.target || ''))
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
      try {
        await run(command)
      } catch (error) {
        const failure = asError(error)
        postError(failure.phase || String(command.type), failure)
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
