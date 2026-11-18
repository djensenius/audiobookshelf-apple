import Foundation
import WebKit

#if os(iOS)
    import UIKit

    typealias EPUBGestureRecognizer = UIGestureRecognizer
#elseif os(macOS)
    import AppKit

    typealias EPUBGestureRecognizer = NSGestureRecognizer
#endif

/// Taps, clicks and swipes on the reader's pages, recognized natively and handed to the reader page
/// (`absReader.touchBegan`, `tap` and `swipe`). epub.js shows each section in a frame sandboxed
/// without scripts (`allowScriptedContent: false`), and WebKit runs no event listener for an event
/// in such a frame, the page's own included, so the page never hears a tap or swipe on the book's
/// text. The recognizers watch alongside WebKit's own, which still get every touch, so selecting
/// text and its menu work as before. Swipes are touch only (a finger or the pencil), on iOS and
/// iPadOS; on the Mac, a click waits out a double-click, which selects a word instead.
@MainActor
final class EPUBPageGestures: NSObject {
    /// A swipe's progress, as the page's `swipe` takes it.
    enum SwipePhase: String {
        case start, move, end, cancel
    }

    private weak var webView: WKWebView?
    /// The recognizers on the web view, until `uninstall`.
    private(set) var recognizers: [EPUBGestureRecognizer] = []
    #if os(iOS)
        /// When the latest touch began, in system uptime.
        private var touchStart: TimeInterval = 0
    #endif

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        recognizers = install(on: webView)
    }

    /// Takes the recognizers off the web view, as the reader closes.
    func uninstall() {
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers = []
    }

    /// A touch or click on the page began, before WebKit acts on it (a tap clears a selection).
    func touchBegan() {
        call("window.absReader.touchBegan()", arguments: [:])
    }

    /// A tap or click at `point`, in the web view's coordinates (the page's CSS pixels).
    func tap(at point: CGPoint) {
        call("window.absReader.tap(x, y)", arguments: ["x": point.x, "y": point.y])
    }

    /// A swipe's `phase` at `point`, in the web view's coordinates.
    func swipe(_ phase: SwipePhase, at point: CGPoint) {
        call("window.absReader.swipe(phase, x, y)", arguments: ["phase": phase.rawValue, "x": point.x, "y": point.y])
    }

    private func call(_ body: String, arguments: [String: Any]) {
        // Nothing to do before the reader page is ready or once it's closed (a blank page).
        webView?.callAsyncJavaScript(
            "if (window.absReader && window.absReader.tap) \(body)", arguments: arguments, in: nil, in: .page)
    }
}

#if os(iOS)
    extension EPUBPageGestures: UIGestureRecognizerDelegate {
        /// How long a touch can be held and still be a tap: longer, it's WebKit's long press (a
        /// selection, or a link's or image's menu), as long as `UILongPressGestureRecognizer`'s.
        static let longPressDuration: TimeInterval = 0.5

        private func install(on webView: WKWebView) -> [EPUBGestureRecognizer] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            for recognizer in [tap, pan] as [UIGestureRecognizer] {
                // WebKit still gets every touch, as it would without these.
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                webView.addGestureRecognizer(recognizer)
            }
            pan.maximumNumberOfTouches = 1
            // Fingers and the pencil swipe; a pointer's click-drag (an iPad's trackpad) selects text.
            pan.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
            // A tap allows some movement; a drag that far is a swipe (or too short to be one), not
            // a tap as well. The pan fails as soon as a tap's finger lifts, so taps aren't delayed.
            tap.require(toFail: pan)
            return [tap, pan]
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view,
                ProcessInfo.processInfo.systemUptime - touchStart < Self.longPressDuration
            else { return }
            tap(at: recognizer.location(in: view))
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                // The pan begins once the finger has moved a little: the swipe starts where it went down.
                let moved = recognizer.translation(in: view)
                swipe(.start, at: CGPoint(x: point.x - moved.x, y: point.y - moved.y))
                swipe(.move, at: point)
            case .changed:
                swipe(.move, at: point)
            case .ended:
                swipe(.end, at: point)
            case .cancelled, .failed:
                swipe(.cancel, at: point)
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Every touch reaches the tap recognizer first, so it's noted once.
            if gestureRecognizer is UITapGestureRecognizer {
                touchStart = touch.timestamp
                touchBegan()
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
#elseif os(macOS)
    extension EPUBPageGestures: NSGestureRecognizerDelegate {
        private func install(on webView: WKWebView) -> [EPUBGestureRecognizer] {
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            // Only there for the click to wait on: a double-click selects a word, not a turn.
            let doubleClick = NSClickGestureRecognizer(target: nil, action: nil)
            doubleClick.numberOfClicksRequired = 2
            for recognizer in [click, doubleClick] {
                // WebKit gets the mouse at once, so dragging still selects text.
                recognizer.delaysPrimaryMouseButtonEvents = false
                recognizer.delegate = self
                webView.addGestureRecognizer(recognizer)
            }
            return [click, doubleClick]
        }

        @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            var point = recognizer.location(in: view)
            if !view.isFlipped { point.y = view.bounds.height - point.y }
            tap(at: point)
        }

        private func isClick(_ recognizer: NSGestureRecognizer) -> Bool {
            recognizer === recognizers.first
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            // Control-click is the context menu's.
            if event.modifierFlags.contains(.control) { return false }
            guard isClick(gestureRecognizer) else { return true }
            if event.type == .leftMouseDown { touchBegan() }
            // A triple-click's third click (a paragraph's selection) isn't a click either.
            return event.clickCount <= 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            isClick(gestureRecognizer) && !isClick(otherGestureRecognizer)
                && recognizers.contains(otherGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool { true }
    }
#endif
