import ABSAPI
import AuthenticationServices
import SwiftUI

/// Opens the identity provider's sign-in page for ``OIDCLoginService`` in SwiftUI's web
/// authentication session.
///
/// Create it in the sign-in view from `@Environment(\.webAuthenticationSession)`. The session
/// intercepts the `audiobookshelf` callback itself, so the scheme needs no `CFBundleURLTypes`
/// entry.
struct WebAuthenticationSessionAuthenticator: WebAuthenticator {
    let session: WebAuthenticationSession
    /// `.shared` (the default, as in the legacy app) shares Safari's cookies, so a user already
    /// signed in to the identity provider isn't asked again; the system first asks for consent.
    /// `.ephemeral` shares nothing and doesn't ask. The default awaits the owner's sign-off.
    var browserSession: WebAuthenticationSession.BrowserSession = .shared

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(
                using: url, callback: .customScheme(callbackScheme), preferredBrowserSession: browserSession,
                additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw OIDCLoginError.cancelled
        }
    }
}
