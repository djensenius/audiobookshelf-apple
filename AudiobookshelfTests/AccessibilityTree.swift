#if os(macOS)
    import AppKit

    /// SwiftUI's accessibility tree on Mac, as VoiceOver finds it: for checking the named actions on
    /// a reader's page. SwiftUI's elements aren't all views, so they're asked through the
    /// NSAccessibility selectors.
    @MainActor
    enum AccessibilityTree {
        /// Runs `body` with SwiftUI building its accessibility tree, as for an attached assistive app.
        /// The flag is the whole app's and tests overlap across their suspensions, so it's counted:
        /// the first user sets it and the last puts back what it was.
        static func with<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
            acquire()
            defer { release() }
            return try await body()
        }

        /// ``with(_:)`` for a synchronous `body`.
        static func with<T>(_ body: @MainActor () throws -> T) rethrows -> T {
            acquire()
            defer { release() }
            return try body()
        }

        private static let key = "accessibilityEnhancedUserInterface"
        private static var users = 0
        private static var original: Any?

        private static func acquire() {
            if users == 0 {
                original = NSApplication.shared.value(forKey: key)
                NSApplication.shared.setValue(true, forKey: key)
            }
            users += 1
        }

        private static func release() {
            users -= 1
            if users == 0 {
                NSApplication.shared.setValue(original, forKey: key)
                original = nil
            }
        }

        /// The element under `root` that contains `view`'s elements: SwiftUI's container for the page,
        /// not a view.
        static func container(of view: NSView, in root: NSView) -> NSObject? {
            elements(in: root).first { element in
                !(element is NSView)
                    && children(of: element).contains { ($0 as? NSView)?.isDescendant(of: view) == true }
            }
        }

        /// The element under `root` labelled `label`.
        static func element(labelled label: String, in root: NSView) -> NSObject? {
            elements(in: root).first { value(of: $0, "accessibilityLabel") == label }
        }

        /// The names of `element`'s custom actions.
        static func actionNames(of element: NSObject) -> [String] {
            customActions(of: element).map(\.name)
        }

        /// Performs `element`'s custom action called `name`; whether it was there and succeeded.
        static func perform(_ name: String, on element: NSObject) -> Bool {
            customActions(of: element).first { $0.name == name }?.handler?() ?? false
        }

        private static func elements(in element: NSObject, depth: Int = 0) -> [NSObject] {
            guard depth < 40 else { return [] }
            return [element] + children(of: element).flatMap { elements(in: $0, depth: depth + 1) }
        }

        private static func children(of element: NSObject) -> [NSObject] {
            (value(of: element, "accessibilityChildren") as [Any]? ?? []).compactMap { $0 as? NSObject }
        }

        private static func customActions(of element: NSObject) -> [NSAccessibilityCustomAction] {
            value(of: element, "accessibilityCustomActions") ?? []
        }

        private static func value<T>(of element: NSObject, _ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue() as? T
        }
    }
#endif
