import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import AuthenticationServices
import SwiftUI

/// Sign-in to the server whose status was read, a port of the login step of
/// `ServerConnectForm.vue`. Username and password are hidden when the server only allows
/// OpenID; the OpenID button uses the label the server's admin set.
struct LoginView: View {
    private enum Field {
        case username, password
    }

    @Bindable var model: ConnectViewModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(verbatim: model.server?.address.description ?? model.address)
                } label: {
                    Text(verbatim: L10n.string("LabelServerAddress"))
                }
                if let html = model.loginMessageHTML {
                    Text(HTMLText.attributedString(from: html))
                }
            }
            if model.showsPlainHTTPWarning {
                PlainHTTPWarningSection()
            }
            if let failure = model.failure {
                ConnectFailureSection(model: model, failure: failure)
            }
            if model.showsPasswordLogin {
                passwordSection
            }
            if model.showsOpenIDLogin {
                Section {
                    Button {
                        let authenticator = WebAuthenticationSessionAuthenticator(session: webAuthenticationSession)
                        Task { await model.signInWithOpenID(using: authenticator) }
                    } label: {
                        ConnectButtonLabel(
                            title: model.openIDButtonTitle ?? L10n.string("ButtonLoginWithOpenID"),
                            isRunning: model.phase == .signingIn(.openID))
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if model.showsPasswordLogin { focus = model.username.isEmpty ? .username : .password }
        }
    }

    private var passwordSection: some View {
        Section {
            TextField(text: $model.username) {
                Text(verbatim: L10n.string("LabelUsername"))
            }
            .textContentType(.username)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .focused($focus, equals: .username)
            .submitLabel(.next)
            .onSubmit { focus = .password }
            SecureField(text: $model.password) {
                Text(verbatim: L10n.string("LabelPassword"))
            }
            .textContentType(.password)
            .focused($focus, equals: .password)
            .submitLabel(.go)
            .onSubmit(signIn)
            Button(action: signIn) {
                ConnectButtonLabel(
                    title: L10n.string("ButtonLogin"), isRunning: model.phase == .signingIn(.password))
            }
            .disabled(!model.canSignIn)
        }
        .disabled(model.isBusy)
    }

    private func signIn() {
        Task { await model.signIn() }
    }
}

// MARK: - Previews

#Preview("Password and OpenID") {
    ConnectPreview(
        PreviewConnectBackend(
            authFormData: AuthFormData(
                authLoginCustomMessage: "<p>Welcome to <strong>Shelf</strong>. Ask David for an account.</p>",
                authOpenIDButtonText: "Sign in with Authentik")),
        drive: ConnectPreview.connect(to: "abs.example.com"))
}

#Preview("OpenID only") {
    ConnectPreview(PreviewConnectBackend(authMethods: [.openID]), drive: ConnectPreview.connect(to: "abs.example.com"))
}

#Preview("Plain HTTP warning") {
    ConnectPreview(
        PreviewConnectBackend(authMethods: [.local]), drive: ConnectPreview.connect(to: "http://abs.example.com"))
}

#Preview("Signing in") {
    ConnectPreview(PreviewConnectBackend(hangsOn: .signingIn(.password))) { model in
        await ConnectPreview.connect(to: "192.168.1.20:13378")(model)
        model.username = "david"
        await model.signIn()
    }
}

#Preview("Invalid credentials") {
    ConnectPreview(PreviewConnectBackend(signInError: ServerValidationError.invalidCredentials)) { model in
        await ConnectPreview.connect(to: "abs.example.com")(model)
        model.username = "david"
        await model.signIn()
    }
}
