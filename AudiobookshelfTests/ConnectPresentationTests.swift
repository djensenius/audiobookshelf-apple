import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import AuthenticationServices
import SwiftUI
import Testing

@testable import Audiobookshelf

#if os(macOS)
    import AppKit
    import Vision

    /// The connect fixtures rendered by both suites below.
    @MainActor private enum ConnectFixture {
        static let openIDButtonText = "Sign in with Test Provider"

        static func login(openIDOnly: Bool) async -> ConnectViewModel {
            let backend = PreviewConnectBackend(
                authMethods: openIDOnly ? [.openID] : [.local, .openID],
                authFormData: AuthFormData(authOpenIDButtonText: openIDButtonText))
            let model = ConnectViewModel(backend: backend, localNetwork: PreviewLocalNetworkAccess())
            await ConnectPreview.connect(to: "https://abs.example.com")(model)
            return model
        }

        static func address(_ address: String) -> ConnectViewModel {
            let model = ConnectViewModel(backend: PreviewConnectBackend(), localNetwork: PreviewLocalNetworkAccess())
            model.address = address
            return model
        }

        static func localNetworkDenied() async -> ConnectViewModel {
            let backend = PreviewConnectBackend(
                validationError: ServerValidationError.httpsUnavailable(ServerAddress("http://nas.local")!))
            let model = ConnectViewModel(backend: backend, localNetwork: PreviewLocalNetworkAccess(denied: true))
            model.customHeaders = [CustomHeader(name: "X-Proxy", value: "preview")]
            await ConnectPreview.connect(to: "nas.local")(model)
            return model
        }

        static func savedServers() -> ConnectViewModel {
            ConnectViewModel(
                backend: PreviewConnectBackend(connections: PreviewConnectBackend.savedServers),
                localNetwork: PreviewLocalNetworkAccess())
        }

        static let reservedHeaders = [CustomHeader(name: "Authorization", value: "preview")]

        static func validating() -> ConnectViewModel {
            let model = ConnectViewModel(
                backend: PreviewConnectBackend(hangsOn: .validating), localNetwork: PreviewLocalNetworkAccess())
            model.address = "https://abs.example.com"
            return model
        }

        /// Hosts `view` offscreen, attaches its rendering as `<name>.png`, and returns both.
        /// Attachments never capture the desktop.
        static func render<V: View>(_ view: V, named name: String) throws -> (view: NSView, png: Data) {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(png, named: "\(name).png")
            return (host, png)
        }

        static func secureFields(in view: NSView) -> [NSSecureTextField] {
            (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields(in: $0) }
        }
    }

    /// Renders each connect view and checks the presentation state that decides its text.
    /// Runs everywhere, including CI VMs without a Neural Engine; ``ConnectOCRTests`` reads the
    /// same renderings back with Vision.
    @MainActor @Suite(.serialized) struct ConnectPresentationTests {
        @Test(arguments: [false, true])
        func authenticationMethodsControlTheRenderedForm(openIDOnly: Bool) async throws {
            let model = await ConnectFixture.login(openIDOnly: openIDOnly)
            let rendered = try ConnectFixture.render(
                LoginView(model: model), named: openIDOnly ? "connect-oidc-only" : "connect-login")
            #expect(ConnectFixture.secureFields(in: rendered.view).isEmpty == openIDOnly)
            #expect(model.showsPasswordLogin == !openIDOnly)
            #expect(model.showsOpenIDLogin)
            #expect(model.openIDButtonTitle == ConnectFixture.openIDButtonText)
        }

        @Test(arguments: [
            ("http://abs.example.com", true), ("http://192.168.1.20", false),
            ("http://nas.local", false), ("https://abs.example.com", false),
        ])
        func addressWarningIsVisibleOnlyForPublicHTTP(address: String, warns: Bool) throws {
            let model = ConnectFixture.address(address)
            _ = try ConnectFixture.render(
                ServerAddressView(model: model), named: warns ? "connect-http-warning" : "connect-address")
            #expect(model.showsPlainHTTPWarning == warns)
        }

        @Test func deniedPermissionShowsSettingsInsteadOfDowngrade() async throws {
            let model = await ConnectFixture.localNetworkDenied()
            _ = try ConnectFixture.render(ServerAddressView(model: model), named: "connect-local-network-denied")
            let failure = try #require(model.failure)
            #expect(failure == .localNetworkDenied)
            #expect(failure.recoveries == [.openSettings, .retry])
            #expect(ConnectFailure.localNetworkSettingsURL?.absoluteString.hasSuffix("Privacy_LocalNetwork") == true)
        }

        @Test func savedServersShowLoggedOutStatus() throws {
            let model = ConnectFixture.savedServers()
            _ = try ConnectFixture.render(ServerListView(model: model), named: "connect-saved-servers")
            #expect(model.savedServers.contains { $0.signedOutAt != nil })
            #expect(model.phase != .signingIn(.savedSession))
        }

        @Test func customHeadersShowValidationAndCanRenderEmpty() throws {
            let headers = ConnectFixture.reservedHeaders
            _ = try ConnectFixture.render(
                CustomHeadersEditor(headers: .constant(headers)), named: "connect-custom-headers")
            #expect(headers.map(\.problem) == [.reservedHeader(name: "Authorization")])
            _ = try ConnectFixture.render(CustomHeadersEditor(headers: .constant([])), named: "connect-no-headers")
        }

        @Test(.timeLimit(.minutes(1)))
        func validatingStateRendersWithoutBlocking() async throws {
            let model = ConnectFixture.validating()
            let validation = Task { await model.submitAddress() }
            while model.phase != .validating { await Task.yield() }
            defer { model.cancel() }
            _ = try ConnectFixture.render(ServerAddressView(model: model), named: "connect-validating")
            #expect(model.isBusy)
            model.cancel()
            await validation.value
        }
    }

    /// Reads the connect renderings back with Vision's accurate text recognition.
    ///
    /// Accurate recognition needs the Neural Engine, which CI's macOS VMs don't have, so this
    /// suite is opt-in: run `TEST_RUNNER_ABS_OCR_TESTS=1 mise run test:app` on a physical Mac.
    @MainActor
    @Suite(
        .serialized,
        .disabled(
            if: ProcessInfo.processInfo.environment["ABS_OCR_TESTS"] != "1",
            "Vision OCR needs a Neural Engine; set TEST_RUNNER_ABS_OCR_TESTS=1 on a physical Mac"))
    struct ConnectOCRTests {
        private struct RenderedForm {
            let view: NSView
            let text: String
        }

        private func host<V: View>(_ view: V, named name: String) async throws -> RenderedForm {
            let rendered = try ConnectFixture.render(view, named: name)
            let png = rendered.png
            // Read only the rendered fixture, not the shared screen. This avoids requiring a
            // system accessibility client to activate SwiftUI's virtual accessibility nodes.
            let text = try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: png).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").replacingOccurrences(of: "’", with: "'")
            }.value
            return RenderedForm(view: rendered.view, text: text)
        }

        @Test(arguments: [false, true])
        func authenticationMethodsControlTheRenderedForm(openIDOnly: Bool) async throws {
            let model = await ConnectFixture.login(openIDOnly: openIDOnly)
            let host = try await host(
                LoginView(model: model), named: openIDOnly ? "connect-oidc-only" : "connect-login")
            #expect(ConnectFixture.secureFields(in: host.view).isEmpty == openIDOnly)
            #expect(host.text.contains("Sign in with Test Provider"))
        }

        @Test(arguments: [
            ("http://abs.example.com", true), ("http://192.168.1.20", false),
            ("http://nas.local", false), ("https://abs.example.com", false),
        ])
        func addressWarningIsVisibleOnlyForPublicHTTP(address: String, warns: Bool) async throws {
            let model = ConnectFixture.address(address)
            let host = try await host(
                ServerAddressView(model: model), named: warns ? "connect-http-warning" : "connect-address")
            #expect(host.text.contains(L10n.string("MessagePlainHTTPWarning")) == warns)
        }

        @Test func deniedPermissionShowsSettingsInsteadOfDowngrade() async throws {
            let model = await ConnectFixture.localNetworkDenied()
            let host = try await host(ServerAddressView(model: model), named: "connect-local-network-denied")
            let labels = host.text
            #expect(labels.contains(ConnectFailure.localNetworkDenied.message))
            #expect(labels.contains(L10n.string("ButtonOpenSettings")))
            #expect(!labels.contains(L10n.string("ButtonConnectWithoutEncryption")))
            #expect(ConnectFailure.localNetworkSettingsURL?.absoluteString.hasSuffix("Privacy_LocalNetwork") == true)
        }

        @Test func savedServersShowLoggedOutStatus() async throws {
            let host = try await host(
                ServerListView(model: ConnectFixture.savedServers()), named: "connect-saved-servers")
            #expect(host.text.contains(L10n.string("LabelLoggedOut")))
        }

        @Test func customHeadersShowValidationAndCanRenderEmpty() async throws {
            let invalid = try await host(
                CustomHeadersEditor(headers: .constant(ConnectFixture.reservedHeaders)), named: "connect-custom-headers"
            )
            #expect(invalid.text.contains(ConnectFailure.reservedHeader(name: "Authorization").message))
            let empty = try await host(CustomHeadersEditor(headers: .constant([])), named: "connect-no-headers")
            #expect(empty.text.contains(L10n.string("MessageNoCustomHeaders")))
        }

        @Test(.timeLimit(.minutes(1)))
        func validatingStateRendersWithoutBlocking() async throws {
            let model = ConnectFixture.validating()
            let validation = Task { await model.submitAddress() }
            while model.phase != .validating { await Task.yield() }
            defer { model.cancel() }
            let host = try await host(ServerAddressView(model: model), named: "connect-validating")
            #expect(model.isBusy)
            #expect(host.text.contains(L10n.string("ButtonConnect")))
            model.cancel()
            await validation.value
        }
    }
#endif

@Suite struct ConnectMessageAndBrowserTests {
    @Test(arguments: [
        ConnectFailure.invalidAddress, .notAudiobookshelf, .localNetworkDenied, .invalidCredentials,
        .unsupportedVersion(nil), .unsupportedVersion("2.0.0"), .accessDenied(status: 403), .unexpected,
        .openID(.browserFailed), .openID(.serverRefused(message: nil)),
    ])
    func failureMessagesResolve(failure: ConnectFailure) {
        #expect(!failure.message.isEmpty)
        #expect(!failure.message.hasPrefix("Message"))
        #expect(!failure.message.contains("%1$@"))
    }

    @Test func onlyAnHTTPSFailureOffersConnectingWithoutEncryption() throws {
        let fallback = try #require(ServerAddress("http://nas.local"))
        #expect(ConnectFailure.httpsUnavailable(fallback).recoveries == [.connectWithoutEncryption])
        let denied = ConnectFailure.localNetworkDenied.recoveries
        #expect(!denied.contains(.connectWithoutEncryption))
        #expect(denied.last == .retry)
        #expect(denied.contains(.openSettings) == (ConnectFailure.localNetworkSettingsURL != nil))
        #expect(ConnectFailure.notAudiobookshelf.recoveries.isEmpty)
    }

    @Test func serverSuppliedTextStaysLiteral() {
        let value = "[server](https://example.com) **name**"
        #expect(ConnectFailure.redirectedToOtherHost(value).message.contains(value))
        #expect(ConnectFailure.openID(.identityProvider(error: value, description: nil)).message.contains(value))
    }

    @Test func browserForwardsTheURLAndCallbackScheme() async throws {
        let url = try #require(URL(string: "https://idp.example.com/authorize"))
        let callback = try #require(URL(string: "audiobookshelf://oauth?code=test"))
        let browser = WebAuthenticationSessionAuthenticator { requested, scheme in
            #expect(requested == url)
            #expect(scheme == OIDCLoginService.callbackScheme)
            return callback
        }
        #expect(try await browser.authenticate(url, callbackScheme: OIDCLoginService.callbackScheme) == callback)
    }

    @Test func browserCancellationIsSilent() async throws {
        let browser = WebAuthenticationSessionAuthenticator { _, _ in
            throw ASWebAuthenticationSessionError(.canceledLogin)
        }
        await #expect(throws: OIDCLoginError.cancelled) {
            try await browser.authenticate(URL(string: "https://idp.example.com")!, callbackScheme: "audiobookshelf")
        }
    }
}
