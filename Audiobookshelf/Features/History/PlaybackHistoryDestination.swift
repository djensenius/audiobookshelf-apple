import SwiftUI

/// The `Route.history` screen. A stub until the history store and player are wired into the
/// app environment, which then builds ``PlaybackHistoryView`` here.
struct PlaybackHistoryDestination: View {
    let itemID: String
    let episodeID: String?

    var body: some View {
        FeatureStub(
            titleKey: "ButtonHistory", systemImage: "clock.arrow.circlepath",
            details: [itemID] + (episodeID.map { [$0] } ?? []))
    }
}

#Preview {
    NavigationStack { PlaybackHistoryDestination(itemID: "li_1", episodeID: nil) }
}
