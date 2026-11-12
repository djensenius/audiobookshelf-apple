import SwiftUI

/// Accessibility shared by the cards and rows that VoiceOver reads as one long label.
enum CardAccessibility {
    /// The Voice Control names of a card or row: its visible title first, so "Tap Dune" works
    /// and Show Names shows it, then its full VoiceOver label, which Voice Control would
    /// otherwise need spoken in full.
    static func inputLabels(title: String, label: String) -> [String] {
        title == label ? [title] : [title, label]
    }
}

extension View {
    /// Names a card or row for Voice Control by its visible `title` as well as its VoiceOver
    /// `label` (``CardAccessibility/inputLabels(title:label:)``).
    public func cardInputLabels(title: String, label: String) -> some View {
        accessibilityInputLabels(CardAccessibility.inputLabels(title: title, label: label).map { Text(verbatim: $0) })
    }
}
