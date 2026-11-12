import SwiftUI

/// The square "E" shown next to explicit titles.
public struct ExplicitBadge: View {
    public init() {}

    public var body: some View {
        MediaBadge(systemImage: "e.square.fill", labelKey: "LabelExplicit")
    }
}

/// The square "A" shown next to abridged titles.
public struct AbridgedBadge: View {
    public init() {}

    public var body: some View {
        MediaBadge(systemImage: "a.square.fill", labelKey: "LabelAbridged")
    }
}

private struct MediaBadge: View {
    let systemImage: String
    let labelKey: String

    var body: some View {
        // Sized by the surrounding font, so it scales with Dynamic Type.
        // A letter shape, not a colour, carries the meaning. VoiceOver reads the word, not an image.
        Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.string(labelKey)))
            .accessibilityRemoveTraits(.isImage)
    }
}
