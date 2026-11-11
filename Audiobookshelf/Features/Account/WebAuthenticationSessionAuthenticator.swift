import ABSAPI
import AuthenticationServices
import SwiftUI

/// Opens the identity provider's sign-in page for ``OIDCLoginService`` in SwiftUI's web
/// authentication session.
///
/// Create it in the sign-in view from `@Environment(\.webAuthenticationSession)`. The session
/// intercepts the `audiobookshelf` callback before the app's deep-link handler.
struct WebAuthenticationSessionAuthenticator: WebAuthenticator {
    private let open: @Sendable (URL, String) async throws -> URL

    /// `.shared` (the default, as in the legacy app) shares Safari's cookies, so a user already
    /// signed in to the identity provider isn't asked again; the system first asks for consent.
    /// `.ephemeral` shares nothing and doesn't ask.
    init(session: WebAuthenticationSession, browserSession: WebAuthenticationSession.BrowserSession = .shared) {
        open = { url, callbackScheme in
            try await session.authenticate(
                using: url, callback: .customScheme(callbackScheme), preferredBrowserSession: browserSession,
                additionalHeaderFields: [:])
        }
    }

    /// Tests supply a browser operation without opening a real identity provider.
    init(open: @escaping @Sendable (URL, String) async throws -> URL) {
        self.open = open
    }

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await open(url, callbackScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw OIDCLoginError.cancelled
        }
    }
}
