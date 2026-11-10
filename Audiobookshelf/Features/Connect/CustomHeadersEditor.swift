import ABSAppModel
import ABSUI
import SwiftUI

/// Edits the custom headers sent with every request to a server, a port of
/// `CustomHeadersModal.vue`. Blank rows are ignored; a row with a problem says so.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]

    var body: some View {
        Form {
            if headers.isEmpty {
                Section {
                    Text(verbatim: L10n.string("MessageNoCustomHeaders"))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach($headers) { $header in
                Section {
                    field(L10n.string("LabelName"), text: $header.name)
                    field(L10n.string("LabelValue"), text: $header.value)
                    Button(role: .destructive) {
                        headers.removeAll { $0.id == header.id }
                    } label: {
                        Text(verbatim: L10n.string("ButtonRemove"))
                    }
                    .accessibilityLabel(Text(verbatim: removeLabel(header)))
                } footer: {
                    if let problem = header.problem {
                        Text(verbatim: problem.message)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                Button {
                    headers.append(CustomHeader())
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonAddCustomHeader"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } footer: {
                Text(verbatim: L10n.string("MessageCustomHeadersHelp"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string("HeaderCustomHeaders")))
    }

    private func removeLabel(_ header: CustomHeader) -> String {
        let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? L10n.string("LabelRemoveUnnamedCustomHeader") : L10n.string("LabelRemoveCustomHeader", name)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(text: text) {
            Text(verbatim: label)
        }
        .autocorrectionDisabled()
        #if os(iOS)
            .textInputAutocapitalization(.never)
        #endif
    }
}

// MARK: - Previews

#Preview("Custom headers") {
    @Previewable @State var headers = [
        CustomHeader(name: "CF-Access-Client-Id", value: "abc.access"),
        CustomHeader(name: "Authorization", value: "Basic dXNlcjpwdw=="),
    ]
    NavigationStack {
        CustomHeadersEditor(headers: $headers)
    }
}

#Preview("No custom headers") {
    @Previewable @State var headers: [CustomHeader] = []
    NavigationStack {
        CustomHeadersEditor(headers: $headers)
    }
}
