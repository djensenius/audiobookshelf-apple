import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Item rows in a lazy stack, the Library screen's list mode: like ``BrowseItemGrid``, a row opens its screen and
/// performs its context-menu actions through the environment (``ItemCardActions``), with an alert when one fails.
struct LibraryItemList: View {
    let items: [ItemSummary]
    var onAppear: (ItemSummary) -> Void = { _ in }
    /// Rows call `onAppear` again when this changes, as rows a refresh kept don't appear again to page on.
    var appearanceID = 0
    @Environment(Router.self) private var router: Router?
    @Environment(\.serverID) private var serverID
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false

    var body: some View {
        let context = ItemCardActions.actionContext(canPlay: playItem != nil)
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                ItemRow(item: item, serverID: serverID, context: context) { perform($0, on: item) }
                    .padding(.horizontal, ABSSpacing.large)
                    .padding(.vertical, ABSSpacing.small)
                    .task(id: appearanceID) { onAppear(item) }
                Divider()
                    .padding(.leading, ABSSpacing.large)
            }
        }
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    private func perform(_ kind: ItemActionKind, on item: ItemSummary) {
        guard kind != .openDetails else {
            BrowsePresentation.open(ItemCardActions.route(for: item), in: router)
            return
        }
        let actions = itemActions
        let play = playItem
        Task {
            if let key = await ItemCardActions.perform(kind, on: item, actions: actions, play: play) {
                failureKey = key
                showsFailure = true
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
