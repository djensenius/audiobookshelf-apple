import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// A new server's address and custom headers, a port of the address step of
/// `ServerConnectForm.vue`. Connecting reads the server's `/status`.
struct ServerAddressView: View {
    @Bindable var model: ConnectViewModel

    var body: some View {
        Form {
            Section {
                TextField(text: $model.address, prompt: Text(verbatim: "https://abs.example.com")) {
                    Text(verbatim: L10n.string("LabelServerAddress"))
                }
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.go)
                .onSubmit(connect)
                NavigationLink {
                    CustomHeadersEditor(headers: $model.customHeaders)
                } label: {
                    LabeledContent {
                        Text(model.customHeaders.count, format: .number)
                    } label: {
                        Text(verbatim: L10n.string("HeaderCustomHeaders"))
                    }
                }
            }
            .disabled(model.isBusy)
            if model.showsPlainHTTPWarning {
                PlainHTTPWarningSection()
            }
            if let failure = model.failure {
                ConnectFailureSection(model: model, failure: failure)
            }
            Section {
                Button(action: connect) {
                    ConnectButtonLabel(title: L10n.string("ButtonConnect"), isRunning: model.isBusy)
                }
                .disabled(model.isBusy || model.address.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(L10n.attributed("MessageAudiobookshelfServerRequired"))
            }
        }
        .formStyle(.grouped)
    }

    private func connect() {
        Task { await model.submitAddress() }
    }
}

// MARK: - Previews

#Preview("Address") {
    ConnectPreview()
}

#Preview("Plain HTTP warning") {
    ConnectPreview { $0.address = "http://abs.example.com" }
}

#Preview("Validating") {
    ConnectPreview(PreviewConnectBackend(hangsOn: .validating), drive: ConnectPreview.connect(to: "abs.example.com"))
}

#Preview("Not Audiobookshelf") {
    ConnectPreview(
        PreviewConnectBackend(validationError: ServerValidationError.notAudiobookshelf),
        drive: ConnectPreview.connect(to: "example.com"))
}

#Preview("HTTPS unavailable") {
    if let fallback = ServerAddress("http://abs.example.com") {
        ConnectPreview(
            PreviewConnectBackend(validationError: ServerValidationError.httpsUnavailable(fallback)),
            drive: ConnectPreview.connect(to: "abs.example.com"))
    }
}

#Preview("Local network denied") {
    ConnectPreview(
        PreviewConnectBackend(validationError: ServerValidationError.cannotConnect(.cannotConnectToHost)),
        deniesLocalNetwork: true, drive: ConnectPreview.connect(to: "192.168.1.20:13378"))
}
