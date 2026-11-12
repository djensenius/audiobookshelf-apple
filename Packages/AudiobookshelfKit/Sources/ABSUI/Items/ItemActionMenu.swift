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
    /// Adds `actions` as a context menu and, with the same titles, as VoiceOver actions. The
    /// VoiceOver list omits ``ItemActionKind/openDetails``, which the default activation performs.
    public func itemActions(_ actions: [ItemAction], perform: @escaping (ItemActionKind) -> Void) -> some View {
        itemActions(actions, perform: perform) { EmptyView() }
    }

    /// Adds `actions` as ``itemActions(_:perform:)`` does, followed by the screen's own buttons in `more`, in the
    /// context menu and the VoiceOver actions alike.
    public func itemActions<More: View>(
        _ actions: [ItemAction], perform: @escaping (ItemActionKind) -> Void, @ViewBuilder more: () -> More
    ) -> some View {
        let more = more()
        return contextMenu {
            ItemActionMenu(actions: actions, perform: perform)
            more
        }
        .accessibilityActions {
            ForEach(actions.filter { $0.kind != .openDetails }) { action in
                Button(ItemPresentation.title(action.kind)) { perform(action.kind) }
            }
            more
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
