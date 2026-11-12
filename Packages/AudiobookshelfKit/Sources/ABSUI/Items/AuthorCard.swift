import ABSCore
import SwiftUI

/// An author as a photo with the name and book count (port of legacy `AuthorCard.vue`). A tap
/// calls `onOpen`.
public struct AuthorCard: View {
    private let author: AuthorSummary
    private let serverID: UUID?
    private let onOpen: () -> Void

    public init(author: AuthorSummary, serverID: UUID?, onOpen: @escaping () -> Void) {
        self.author = author
        self.serverID = serverID
        self.onOpen = onOpen
    }

    public var body: some View {
        let count = author.bookCount.map { ItemPresentation.bookCount($0) }
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                AuthorImageView(key: serverID.flatMap { author.imageKey(serverID: $0) }, name: author.name)
                    .aspectRatio(0.8, contentMode: .fit)
                Text(verbatim: author.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(ABSColor.foreground)
                if let count {
                    Text(verbatim: count)
                        .font(.caption)
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .itemHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ItemPresentation.accessibilityLabel(author)))
        .cardInputLabels(title: author.name, label: ItemPresentation.accessibilityLabel(author))
        .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Author card") {
    HStack(alignment: .top) {
        ForEach(SampleLibrary.authors.prefix(3)) {
            AuthorCard(author: AuthorSummary(author: $0), serverID: UUID()) {}
                .frame(width: 120)
        }
    }
    .padding()
    .absBackground()
}
