import Foundation
import WebKit

/// Taps, clicks and swipes on the reader's pages, recognized natively and handed to the reader page
/// (`absReader.touchBegan`, `tap` and `swipe`). epub.js shows each section in a frame sandboxed
/// without scripts (`allowScriptedContent: false`), and WebKit runs no event listener for an event
/// in such a frame, the page's own included, so the page never hears a tap or swipe on the book's
/// text. The recognizers watch alongside WebKit's own, which still get every touch, so selecting
/// text, its menu and links work as before. Swipes are touch only, on iOS and iPadOS.
@MainActor
final class EPUBPageGestures: NSObject {
    /// A swipe's progress, as the page's `swipe` takes it.
    enum SwipePhase: String {
        case start, move, end, cancel
    }

    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        install(on: webView)
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
    import UIKit

    extension EPUBPageGestures: UIGestureRecognizerDelegate {
        private func install(on webView: WKWebView) {
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
            // A tap allows some movement; a drag that far is a swipe (or too short to be one), not
            // a tap as well. The pan fails as soon as a tap's finger lifts, so taps aren't delayed.
            tap.require(toFail: pan)
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
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
            if gestureRecognizer is UITapGestureRecognizer { touchBegan() }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
#elseif os(macOS)
    import AppKit

    extension EPUBPageGestures: NSGestureRecognizerDelegate {
        private func install(on webView: WKWebView) {
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            // WebKit gets the mouse at once, so dragging still selects text.
            click.delaysPrimaryMouseButtonEvents = false
            click.delegate = self
            webView.addGestureRecognizer(click)
        }

        @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            var point = recognizer.location(in: view)
            if !view.isFlipped { point.y = view.bounds.height - point.y }
            tap(at: point)
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            if event.type == .leftMouseDown { touchBegan() }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool { true }
    }
#endif
