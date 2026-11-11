import ABSAppModel
import SwiftUI

/// The Add podcast section of a podcast library, for users who may add podcasts (legacy
/// `pages/bookshelf/add-podcast.vue`). A stub until the Podcasts feature replaces this file.
struct AddPodcastView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.addPodcast.titleKey, systemImage: AppTab.addPodcast.systemImage)
    }
}

#Preview {
    NavigationStack { AddPodcastView() }
}
