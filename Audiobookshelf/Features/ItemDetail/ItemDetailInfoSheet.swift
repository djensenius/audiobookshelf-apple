import ABSAppModel
import ABSUI
import SwiftUI

/// The book's details from the More menu's More info (legacy `ItemDetailsModal.vue`): its
/// title, size and ID. The ID is selectable, for support requests; it isn't a secret.
struct ItemDetailInfoSheet: View {
    let model: ItemDetailModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            Form {
                if let details = model.details {
                    LabeledContent {
                        Text(verbatim: details.title)
                    } label: {
                        Text(verbatim: L10n.string("LabelTitle"))
                    }
                    if let size = details.size, size > 0 {
                        LabeledContent {
                            Text(verbatim: Int64(size).formatted(.byteCount(style: .file).locale(locale)))
                        } label: {
                            Text(verbatim: L10n.string("LabelSize"))
                        }
                    }
                }
                LabeledContent {
                    Text(verbatim: model.itemID)
                        .textSelection(.enabled)
                } label: {
                    Text(verbatim: L10n.string("LabelItemDetailID"))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: L10n.string("HeaderDetails")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(verbatim: L10n.string("ButtonItemDetailClose"))
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 240)
        #endif
        .presentationDetents([.medium, .large])
    }
}

#Preview("Details") {
    @Previewable @State var model = ItemDetailModel(
        itemID: ItemDetailPreviewData.book.id,
        service: PreviewItemDetailService(item: ItemDetailPreviewData.book, behavior: .succeed), cache: ProgressCache())
    ItemDetailInfoSheet(model: model)
        .task { await model.loadIfNeeded() }
}
