import ABSAppModel
import SwiftUI

/// The Series section of a book library (legacy `pages/bookshelf/series/index.vue`). A stub
/// until the Series feature replaces this file.
struct SeriesView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.series.titleKey, systemImage: AppTab.series.systemImage)
    }
}

/// One series (legacy `pages/bookshelf/series/_id.vue`). A stub until the Series feature
/// replaces this file.
struct SeriesDetailView: View {
    let seriesID: String

    var body: some View {
        FeatureStub(titleKey: "LabelSeries", systemImage: AppTab.series.systemImage, details: [seriesID])
    }
}

#Preview("Series") {
    NavigationStack { SeriesView() }
}

#Preview("Detail") {
    NavigationStack { SeriesDetailView(seriesID: "se_1") }
}
