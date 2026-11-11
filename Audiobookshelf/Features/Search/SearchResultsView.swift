import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The search results as a list of sections in the legacy order, under a notice when the last
/// search failed and a spinner while a newer one runs.
struct SearchResultsView: View {
    let sections: [SearchResultSection]
    var isSearching = false
    var failed = false
    let open: (Route) -> Void
    let retry: () -> Void

    var body: some View {
        List {
            if failed {
                SearchFailedRow(retry: retry)
            }
            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text(verbatim: L10n.string("MessageFetching")))
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        SearchResultRowView(row: row, kind: section.kind) { open(row.route) }
                    }
                } header: {
                    Text(verbatim: L10n.string(SearchPresentation.titleKey(of: section.kind)))
                }
            }
        }
    }
}

/// One result: a cover, series covers, author photo or icon, its title and a second line, like
/// the legacy search cards. A tap opens its route.
struct SearchResultRowView: View {
    let row: SearchResultRow
    let kind: SearchSectionKind
    let open: () -> Void
    @ScaledMetric(relativeTo: .body) private var imageWidth: CGFloat = 44
    @Environment(\.serverID) private var serverID
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: open) {
            HStack(spacing: ABSSpacing.medium) {
                leading
                    .frame(width: min(imageWidth, 96))
                VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                    Text(verbatim: SearchPresentation.title(of: row))
                        .font(.body)
                        .lineLimit(2)
                        .foregroundStyle(ABSColor.foreground)
                    if let subtitle = SearchPresentation.subtitle(of: row, locale: locale) {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: SearchPresentation.accessibilityLabel(of: row, in: kind, locale: locale)))
        .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var leading: some View {
        switch row.content {
        case .item(let item):
            CoverView(
                key: serverID.flatMap { item.coverKey(serverID: $0, bucket: .small) }, title: item.title,
                shape: item.kind == .book ? .book : .square, accessibility: .hidden)
        case .series(let series):
            GroupCoverView(
                name: series.name,
                keys: serverID.map { id in series.covers.map { $0.key(serverID: id, bucket: .small) } } ?? []
            )
            .aspectRatio(1.25, contentMode: .fit)
        case .author(let author):
            AuthorImageView(
                key: serverID.flatMap { author.imageKey(serverID: $0, bucket: .small) }, name: author.name
            )
            .aspectRatio(1, contentMode: .fit)
        case .name:
            Image(systemName: SearchPresentation.systemImage(of: kind))
                .font(.title2)
                .foregroundStyle(ABSColor.mutedForeground)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Shown above the retained results when the last search failed.
private struct SearchFailedRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string("MessageSearchLibraryFailed"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            Spacer(minLength: ABSSpacing.small)
            Button(action: retry) {
                Text(verbatim: L10n.string("ButtonRetry"))
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
    /// Fixture results for previews: every section of a book library, and a podcast's.
    enum SearchPreviewData {
        static let sections = SearchResultGroups(
            LibrarySearchResults(
                books: [SampleLibrary.emma, SampleLibrary.prideAndPrejudice], podcasts: [SampleLibrary.podcast],
                episodes: SampleLibrary.episodeItems,
                series: SampleLibrary.series.map {
                    LibrarySearchResults.SeriesMatch(series: $0, books: $0.books ?? [])
                },
                authors: SampleLibrary.authors,
                narrators: [LibrarySearchResults.NameMatch(name: "Stephen Fry", count: 3)],
                tags: [LibrarySearchResults.NameMatch(name: "Classics", count: 12)])
        ).sections
    }

    #Preview("Result rows") {
        List {
            ForEach(SearchPreviewData.sections) { section in
                ForEach(section.rows) { row in
                    SearchResultRowView(row: row, kind: section.kind) {}
                }
            }
        }
        .environment(\.serverID, UUID())
    }
#endif
