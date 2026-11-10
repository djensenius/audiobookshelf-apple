import ABSAPI
import ABSAppModel
import ABSData
import ABSUI
import SwiftUI

/// Saved servers, a port of the server list in `ServerConnectForm.vue`: select one to resume
/// its session, remove one, or add a new one.
struct ServerListView: View {
    let model: ConnectViewModel
    @State private var pendingRemoval: ServerConnectionDTO?

    var body: some View {
        Form {
            if let failure = model.failure {
                ConnectFailureSection(model: model, failure: failure)
            }
            Section {
                ForEach(model.savedServers) { server in
                    Button {
                        Task { await model.select(server) }
                    } label: {
                        row(server)
                    }
                    .disabled(model.isBusy)
                    .contextMenu { removeButton(server) }
                    .swipeActions { removeButton(server) }
                }
            }
            Section {
                Button {
                    model.addServer()
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonAddNewServer"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .disabled(model.isBusy)
            } footer: {
                Text(L10n.attributed("MessageAudiobookshelfServerRequired"))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmDeleteServerConfig")),
            isPresented: Binding {
                pendingRemoval != nil
            } set: {
                if !$0 { pendingRemoval = nil }
            },
            titleVisibility: .visible, presenting: pendingRemoval
        ) { server in
            Button(role: .destructive) {
                Task { await model.remove(server) }
            } label: {
                Text(verbatim: L10n.string("ButtonRemove"))
            }
        }
    }

    private func row(_ server: ServerConnectionDTO) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: server.address)
                    .foregroundStyle(.primary)
                Text(verbatim: server.username)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .signingIn(.savedSession), model.savedConnection?.id == server.id {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(.rect)
    }

    private func removeButton(_ server: ServerConnectionDTO) -> some View {
        Button(role: .destructive) {
            pendingRemoval = server
        } label: {
            Label {
                Text(verbatim: L10n.string("ButtonRemove"))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }
}

// MARK: - Previews

#Preview("Saved servers") {
    ConnectPreview(PreviewConnectBackend(connections: PreviewConnectBackend.savedServers))
}

#Preview("Resuming a saved server") {
    ConnectPreview(PreviewConnectBackend(connections: PreviewConnectBackend.savedServers, hangsOn: .validating)) {
        await $0.select(PreviewConnectBackend.savedServers[0])
    }
}

#Preview("Local network denied") {
    ConnectPreview(
        PreviewConnectBackend(
            connections: PreviewConnectBackend.savedServers,
            validationError: ServerValidationError.cannotConnect(.cannotConnectToHost)),
        deniesLocalNetwork: true
    ) {
        await $0.select(PreviewConnectBackend.savedServers[1])
    }
}
