import ABSAppModel
import SwiftUI

/// The Search tab (legacy `pages/search.vue`). A stub until the Search feature replaces this
/// file.
struct SearchView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.search.titleKey, systemImage: AppTab.search.systemImage)
    }
}

#Preview {
    NavigationStack { SearchView() }
}
