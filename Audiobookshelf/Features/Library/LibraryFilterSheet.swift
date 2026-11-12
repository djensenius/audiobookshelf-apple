import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The filter sheet of a library (legacy `FilterModal.vue`): Clear Filter, then the library type's filter groups. A
/// group that takes a value lists its values (from `model`, or the fixed progress and ebook values); one that takes
/// none applies directly. Choosing calls `onSelect` and closes the sheet; the caller decides what the filter does
/// (save it, or open a screen filtered by it).
struct LibraryFilterSheet: View {
    let libraryID: String
    let mediaType: MediaType
    let model: LibraryFilterModel
    /// The filter in use, checked in the sheet.
    let selection: LibraryViewPreferences.Filter?
    /// The chosen filter; `nil` clears it.
    let onSelect: (LibraryViewPreferences.Filter?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        choose(nil)
                    } label: {
                        Text(verbatim: L10n.string("ButtonClearFilter"))
                    }
                    .disabled(selection == nil)
                }
                Section {
                    ForEach(LibraryFilterGroup.groups(for: mediaType), id: \.self) { group in
                        groupRow(group)
                    }
                }
            }
            .navigationTitle(Text(verbatim: L10n.string("HeaderLibraryFilter")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: LibraryFilterGroup.self) { group in
                LibraryFilterValueList(
                    group: group, model: model, selection: selection?.group == group ? selection?.value : nil
                ) { choose(LibraryViewPreferences.Filter(group: group, value: $0)) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(verbatim: L10n.string("ButtonLibraryFilterDone"))
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 520)
        #endif
        .task(id: libraryID) { model.load(libraryID: libraryID) }
    }

    @ViewBuilder
    private func groupRow(_ group: LibraryFilterGroup) -> some View {
        let title = L10n.string(LibraryPresentation.titleKey(for: group))
        let isSelected = selection?.group == group
        if group.needsValue {
            NavigationLink(value: group) {
                LabeledContent {
                    if isSelected {
                        Text(verbatim: LibraryPresentation.filterSummary(selection, choices: model.choices))
                            .lineLimit(1)
                    }
                } label: {
                    Text(verbatim: title)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            LibraryFilterRow(title: title, isSelected: isSelected) {
                choose(LibraryViewPreferences.Filter(group: group))
            }
        }
    }

    private func choose(_ filter: LibraryViewPreferences.Filter?) {
        onSelect(filter)
        dismiss()
    }
}

/// The values of one filter group, with the loading and failed states of the library's filter data.
private struct LibraryFilterValueList: View {
    let group: LibraryFilterGroup
    let model: LibraryFilterModel
    /// The group's value in use.
    let selection: String?
    let choose: (String) -> Void

    var body: some View {
        let values = LibraryPresentation.filterValues(for: group, choices: model.choices)
        Group {
            if let values, values.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: L10n.string("MessageLibraryFilterNoValues"))
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            } else if let values {
                List(values) { value in
                    LibraryFilterRow(title: value.name, isSelected: value.id == selection) { choose(value.id) }
                }
            } else if model.error != nil, !model.isLoading {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: L10n.string("MessageLibraryFilterLoadFailed"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } actions: {
                    Button {
                        model.reload()
                    } label: {
                        Text(verbatim: L10n.string("ButtonRetry"))
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(LibraryPresentation.titleKey(for: group))))
    }
}

/// A choice in the filter sheet, checked when in use.
private struct LibraryFilterRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: ABSSpacing.small)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
    /// Serves fixed filter data, or fails when `fails`.
    private struct FilterPreviewService: LibraryService {
        struct Failure: Error {}

        var fails = false

        func libraries() async throws -> [Library] { [] }
        func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
        func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
            PagedResults(results: [], total: 0, limit: 0, page: 0)
        }

        func library(id: String) async throws -> LibraryWithFilterData {
            if fails { throw Failure() }
            return LibraryWithFilterData(
                library: Library(id: id, name: "Books", mediaType: .book),
                filterData: LibraryFilterData(
                    authors: [Author(id: "aut_1", name: "Jane Austen"), Author(id: "aut_2", name: "Mark Twain")],
                    series: [Series(id: "ser_1", name: "Barsoom")], genres: ["Fantasy", "Science Fiction"],
                    tags: ["Favorites"], narrators: ["Stephen Fry"], languages: ["English"]))
        }
    }

    #Preview("Books, genre selected") {
        LibraryFilterSheet(
            libraryID: "lib_books", mediaType: .book, model: LibraryFilterModel(client: FilterPreviewService()),
            selection: LibraryViewPreferences.Filter(group: .genres, value: "Fantasy"), onSelect: { _ in })
    }

    #Preview("Podcasts, failed, largest text") {
        LibraryFilterSheet(
            libraryID: "lib_podcasts", mediaType: .podcast,
            model: LibraryFilterModel(client: FilterPreviewService(fails: true)), selection: nil, onSelect: { _ in }
        )
        .environment(\.dynamicTypeSize, .accessibility3)
    }
#endif
