import ABSCore
import SwiftUI

/// The buttons for `actions`, for a context menu or a menu button.
public struct ItemActionMenu: View {
    private let actions: [ItemAction]
    private let perform: (ItemActionKind) -> Void

    public init(actions: [ItemAction], perform: @escaping (ItemActionKind) -> Void) {
        self.actions = actions
        self.perform = perform
    }

    public var body: some View {
        ForEach(actions) { action in
            Button {
                perform(action.kind)
            } label: {
                Label(ItemPresentation.title(action.kind), systemImage: ItemPresentation.systemImage(action.kind))
            }
        }
    }
}

extension View {
    /// Adds `actions` as a context menu and, with the same titles, as VoiceOver actions.
    public func itemActions(_ actions: [ItemAction], perform: @escaping (ItemActionKind) -> Void) -> some View {
        contextMenu { ItemActionMenu(actions: actions, perform: perform) }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(ItemPresentation.title(action.kind)) { perform(action.kind) }
                }
            }
    }
}

#Preview("Action menu") {
    let item = ItemSummary(item: SampleLibrary.frankenstein)
    let actions = ItemAction.available(
        for: item, progress: SampleLibrary.progress[item.progressKey],
        context: ItemActionContext(canEditPlaylists: true))
    Menu("Actions") {
        ItemActionMenu(actions: actions) { _ in }
    }
    .padding()
    .absBackground()
}
