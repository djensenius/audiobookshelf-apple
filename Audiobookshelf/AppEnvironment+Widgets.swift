import ABSAppModel
import ABSCore
import ABSData
import Foundation
import WidgetKit

/// Reloads widget timelines through `WidgetCenter`.
@MainActor
final class WidgetCenterReloader: WidgetTimelineReloading {
    func reloadTimelines(ofKind kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

/// Reloads nothing: a fixture or test environment's writer, so it never touches the user's widget.
@MainActor
final class NoWidgetReloads: WidgetTimelineReloading {
    func reloadTimelines(ofKind kind: String) {}
}

extension AppEnvironment {
    /// The Continue Listening widget's snapshot writer (#89): a ``SessionStage/connect``
    /// participant that clears the snapshot on sign-out, once its connection is removed, when the
    /// launch's restore ends signed out, and when a switch back to its connection does.
    ///
    /// Only the App Group store (`storeLocation` `.appGroup`, the real app) writes the shared
    /// snapshot and reloads the widget. A fixture or test environment (an in-memory or file store)
    /// writes nothing and reloads nothing, so its empty accounts can't clear the user's widget.
    /// Without an App Group container (an unsigned macOS build) it writes nothing either.
    static func makeWidgetSnapshotWriter(
        accounts: AccountManager?, lifecycle: SessionLifecycle, storeLocation: DataStack.Location
    ) -> WidgetSnapshotWriter {
        let shared = storeLocation == .appGroup
        let writer = WidgetSnapshotWriter(
            fileURL: shared ? WidgetSnapshot.defaultFileURL() : nil,
            reloader: shared ? WidgetCenterReloader() : NoWidgetReloads())
        writer.followLaunch { lifecycle.gate }
        writer.followRejectedSwitches { (lifecycle.signedOutSwitches, lifecycle.signedOutSwitchConnectionID) }
        if let accounts {
            writer.followRemovals { Set(accounts.connections.map(\.id)) }
        }
        // TODO(#56): call `writer.follow(_:)` with the app's `PlayerViewModel` once the player UI
        // composes it; `player` is still a placeholder, so nothing writes a snapshot yet.
        return writer
    }
}
