import ABSUI
import SwiftUI

/// The library picker at the top of the sidebar (`tabViewSidebarHeader`). A placeholder until
/// the library switcher (S7a) fills it.
struct LibraryPickerHeader: View {
    var body: some View {
        Label {
            Text(verbatim: L10n.string("HeaderLibraries"))
        } icon: {
            Image(systemName: "books.vertical")
        }
        .font(.headline)
    }
}

#Preview {
    LibraryPickerHeader()
}
