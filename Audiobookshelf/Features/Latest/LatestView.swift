import ABSAppModel
import SwiftUI

/// The Latest section of a podcast library (legacy `pages/bookshelf/latest.vue`). A stub until
/// the Latest feature replaces this file.
struct LatestView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.latest.titleKey, systemImage: AppTab.latest.systemImage)
    }
}

#Preview {
    NavigationStack { LatestView() }
}
