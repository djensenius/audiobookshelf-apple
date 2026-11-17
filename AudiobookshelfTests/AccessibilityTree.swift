#if os(macOS)
    import AppKit

    /// SwiftUI's accessibility tree on Mac, as VoiceOver finds it: for checking the named actions on
    /// a reader's page. SwiftUI's elements aren't all views, so they're asked through the
    /// NSAccessibility selectors.
    @MainActor
    enum AccessibilityTree {
        /// Has SwiftUI build its accessibility tree, as an attached assistive app does. Returns the undo.
        static func build() -> () -> Void {
            let app = NSApplication.shared
            let key = "accessibilityEnhancedUserInterface"
            let was = app.value(forKey: key)
            app.setValue(true, forKey: key)
            return { app.setValue(was, forKey: key) }
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
