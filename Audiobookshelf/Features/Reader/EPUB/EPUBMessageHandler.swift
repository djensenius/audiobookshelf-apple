import Foundation
import WebKit

/// Receives the reader page's events (the `absReader` message handler) and hands each one on as
/// JSON `Data`, undecoded: decoding is the reader model's job.
@MainActor
final class EPUBMessageHandler: NSObject, WKScriptMessageHandler {
    /// The name the page posts to: `window.webkit.messageHandlers.absReader`.
    static let name = "absReader"

    var onEvent: (Data) -> Void

    init(onEvent: @escaping (Data) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    /// Adds this handler to `controller` without the controller retaining it, so whatever owns the
    /// handler (and the web view) isn't kept alive by its own web view. Once the handler is gone,
    /// events are dropped.
    func install(in controller: WKUserContentController) {
        controller.add(WeakMessageForwarder(target: self), name: Self.name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = Self.json(from: message.body) else { return }
        onEvent(data)
    }

    /// The event as JSON, or `nil` when the body isn't a JSON object.
    static func json(from body: Any) -> Data? {
        // `data(withJSONObject:)` raises rather than throws on values JSON can't hold.
        guard body is [String: Any], JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }
}

/// Forwards to a handler it doesn't retain: `WKUserContentController` retains its handlers.
@MainActor
private final class WeakMessageForwarder: NSObject, WKScriptMessageHandler {
    weak var target: EPUBMessageHandler?

    init(target: EPUBMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
