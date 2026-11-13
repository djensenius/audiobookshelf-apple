import ABSAppModel
import ABSUI
import SwiftUI

/// The EPUB's table of contents (legacy `Reader.vue`'s TOC modal): its entries indented by level,
/// the current chapter marked. Choosing one shows it (``onSelect``), which closes the sheet.
struct EPUBContentsSheet: View {
    /// `nil` until the page sends the table of contents.
    let contents: EPUBTableOfContents?
    let currentEntryID: Int?
    let onSelect: (EPUBContentsEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var indent = 16

    var body: some View {
        NavigationStack {
            Group {
                if let entries = contents?.entries, !entries.isEmpty {
                    list(entries)
                } else if contents == nil {
                    LoadingView()
                } else {
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: L10n.string("MessageNoChapters"))
                        } icon: {
                            Image(systemName: "list.bullet").accessibilityHidden(true)
                        }
                    }
                }
            }
            .navigationTitle(Text(verbatim: L10n.string("HeaderTableOfContents")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(verbatim: L10n.string("ButtonItemDetailClose"))
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 420)
        #endif
        .presentationDetents([.medium, .large])
    }

    private func list(_ entries: [EPUBContentsEntry]) -> some View {
        ScrollViewReader { proxy in
            List(entries) { entry in
                let isCurrent = entry.id == currentEntryID
                Button {
                    onSelect(entry)
                } label: {
                    HStack {
                        Text(verbatim: entry.label)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isCurrent {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, CGFloat(entry.level) * indent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // VoiceOver's headings rotor moves between entries of one level.
                .accessibilityAddTraits(isCurrent ? [.isHeader, .isSelected] : .isHeader)
                .accessibilityHeading(Self.heading(entry.level))
            }
            .onAppear {
                if let currentEntryID { proxy.scrollTo(currentEntryID, anchor: .center) }
            }
        }
    }

    static func heading(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 0: .h1
        case 1: .h2
        case 2: .h3
        case 3: .h4
        case 4: .h5
        default: .h6
        }
    }
}

#Preview("Contents") {
    EPUBContentsSheet(
        contents: EPUBTableOfContents([
            EPUBTOCItem(
                id: "1", label: "Part One", href: "p1.xhtml",
                subitems: [
                    EPUBTOCItem(id: "1a", label: "Chapter 1", href: "c1.xhtml"),
                    EPUBTOCItem(id: "1b", label: "Chapter 2", href: "c2.xhtml"),
                ]),
            EPUBTOCItem(id: "2", label: "Epilogue", href: "e.xhtml"),
        ]),
        currentEntryID: 2, onSelect: { _ in })
}

#Preview("No contents") {
    EPUBContentsSheet(contents: EPUBTableOfContents([]), currentEntryID: nil, onSelect: { _ in })
}
