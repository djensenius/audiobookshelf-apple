import ABSAppModel
import SwiftUI

/// The Home tab (legacy `pages/bookshelf/index.vue`). A stub until the Home feature replaces
/// this file.
struct HomeView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.home.titleKey, systemImage: AppTab.home.systemImage)
    }
}

#Preview {
    NavigationStack { HomeView() }
}
