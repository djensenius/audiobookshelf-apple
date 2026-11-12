import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Item rows in a lazy stack, the Library screen's list mode: like ``BrowseItemGrid``, a row opens its screen and
/// performs its context-menu actions through ``ItemCardActionsHost``.
struct LibraryItemList: View {
    let items: [ItemSummary]
    var onAppear: (ItemSummary) -> Void = { _ in }
    /// Rows call `onAppear` again when this changes, as rows a refresh kept don't appear again to page on.
    var appearanceID = 0
    @Environment(\.serverID) private var serverID

    var body: some View {
        ItemCardActionsHost { context, perform in
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    ItemRow(item: item, serverID: serverID, context: context) { perform($0, item) }
                        .padding(.horizontal, ABSSpacing.large)
                        .padding(.vertical, ABSSpacing.small)
                        .task(id: appearanceID) { onAppear(item) }
                    Divider()
                        .padding(.leading, ABSSpacing.large)
                }
            }
        }
    }
}

#Preview("Rows") {
    ScrollView {
        LibraryItemList(items: SampleLibrary.books.map { ItemSummary(item: $0) })
    }
    .environment(\.serverID, UUID())
    .absBackground()
}
