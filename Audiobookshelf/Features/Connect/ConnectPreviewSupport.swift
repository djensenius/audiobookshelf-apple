import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import SwiftUI

/// A ``ConnectBackend`` for previews: every server answers with `status`, after `delay`.
@MainActor @Observable
final class PreviewConnectBackend: ConnectBackend {
    var connections: [ServerConnectionDTO]
    var status: ServerStatus
    var validationError: (any Error)?
    var signInError: (any Error)?
    /// Pauses validation or sign-in for an hour, to preview the busy states.
    var hangsOn: ConnectViewModel.Phase?

    init(
        connections: [ServerConnectionDTO] = [], authMethods: [AuthMethod] = [.local, .openID],
        authFormData: AuthFormData? = nil, validationError: (any Error)? = nil, signInError: (any Error)? = nil,
        hangsOn: ConnectViewModel.Phase? = nil
    ) {
        self.connections = connections
        status = ServerStatus(
            app: "audiobookshelf", serverVersion: "2.26.0", isInit: true, authMethods: authMethods,
            authFormData: authFormData)
        self.validationError = validationError
        self.signInError = signInError
        self.hangsOn = hangsOn
    }

    static let savedServers = [
        ServerConnectionDTO(
            id: UUID(), address: "https://abs.example.com", userId: "1", username: "david", authMethod: .local,
            createdAt: .now),
        ServerConnectionDTO(
            id: UUID(), address: "http://192.168.1.20:13378", userId: "2", username: "root", authMethod: .openid,
            createdAt: .now),
    ]

    func validate(address: String, customHeaders: [String: String]) async throws -> ConnectServer {
        try await pause(.validating)
        if let validationError { throw validationError }
        guard let server = ServerAddress(address) else { throw ServerValidationError.invalidAddress }
        return ConnectServer(address: server, status: status)
    }

    func signIn(to server: ConnectServer, username: String, password: String) async throws {
        try await pause(.signingIn(.password))
        if let signInError { throw signInError }
    }

    func signIn(openIDTo server: ConnectServer, authenticator: any WebAuthenticator) async throws {
        try await pause(.signingIn(.openID))
    }

    func resume(_ id: UUID) async throws -> Bool { false }
    func customHeaders(for id: UUID) async throws -> [String: String] { [:] }
    func remove(_ id: UUID) async throws { connections.removeAll { $0.id == id } }

    private func pause(_ phase: ConnectViewModel.Phase) async throws {
        if hangsOn == phase { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// Reports local network access as denied or not, without a connection.
struct PreviewLocalNetworkAccess: LocalNetworkAccessChecking {
    var denied = false

    func isDenied(host: String, port: Int) async -> Bool { denied }
}

/// The connect flow with a preview backend, driven to a state by `drive`.
struct ConnectPreview: View {
    @State private var model: ConnectViewModel
    private let drive: @MainActor (ConnectViewModel) async -> Void

    init(
        _ backend: PreviewConnectBackend = PreviewConnectBackend(), deniesLocalNetwork: Bool = false,
        drive: @escaping @MainActor (ConnectViewModel) async -> Void = { _ in }
    ) {
        _model = State(
            initialValue: ConnectViewModel(
                backend: backend, localNetwork: PreviewLocalNetworkAccess(denied: deniesLocalNetwork)))
        self.drive = drive
    }

    var body: some View {
        ConnectFlowView(model: model)
            .task { await drive(model) }
    }

    /// Enters `address` and connects.
    static func connect(to address: String) -> @MainActor (ConnectViewModel) async -> Void {
        { model in
            model.address = address
            await model.submitAddress()
        }
    }
}
