import ABSCore
import Foundation
import Security
import Testing

@testable import ABSAPI
@testable import ABSAppModel

/// Every error the connect flow can see maps to a failure the app has a localized message for.
@Suite struct ConnectFailureTests {
    private static let fallback = ServerAddress("http://abs.example.com")!

    @Test(arguments: [
        (ServerValidationError.invalidAddress, ConnectFailure.invalidAddress),
        (.reservedHeader(.reserved(name: "Host")), .reservedHeader(name: "Host")),
        (.cannotConnect(.cannotConnectToHost), .cannotConnect),
        (.cannotConnect(.notConnectedToInternet), .cannotConnect),
        (.cannotConnect(.secureConnectionFailed), .secureConnectionFailed),
        (.cannotConnect(.appTransportSecurityRequiresSecureConnection), .insecureConnectionBlocked),
        (.timedOut, .cannotConnect), (.untrustedCertificate, .untrustedCertificate),
        (.httpsUnavailable(fallback), .httpsUnavailable(fallback)), (.notAudiobookshelf, .notAudiobookshelf),
        (.serverNotInitialized, .serverNotInitialized), (.unsupportedVersion("2.0.0"), .unsupportedVersion("2.0.0")),
        (.unsupportedVersion(nil), .unsupportedVersion(nil)), (.accessDenied(status: 403), .accessDenied(status: 403)),
        (.statusFailed(status: 502), .statusFailed(status: 502)),
        (.redirectedToOtherHost("evil.example"), .redirectedToOtherHost("evil.example")),
        (.insecureRedirect, .insecureRedirect), (.loginRedirected, .loginRedirected),
        (.invalidCredentials, .invalidCredentials), (.tooManyAttempts, .tooManyAttempts),
        (.sessionExpired, .sessionExpired), (.missingTokens, .unexpected), (.unexpected(.notFound), .unexpected),
    ])
    func mapsServerValidationErrors(error: ServerValidationError, expected: ConnectFailure) {
        #expect(ConnectFailure(error) == expected)
        // An AccountManager error wrapping it maps the same.
        #expect(ConnectFailure(AccountError.server(error)) == expected)
    }

    @Test(arguments: [
        OIDCLoginError.notEnabled, .authorizationFailed(status: 404), .invalidAuthorizationURL,
        .insecureAuthorizationURL, .browserFailed, .invalidCallback,
        .identityProvider(error: "access_denied", description: "Not in group"),
        .identityProvider(error: "access_denied", description: nil), .stateMismatch, .missingCode, .sessionLost,
        .rejected, .serverRefused(message: "Unauthorized"), .serverRefused(message: nil),
        .callbackFailed(status: 500),
    ])
    func mapsOpenIDErrorsForLocalizedMessages(error: OIDCLoginError) {
        #expect(ConnectFailure(error) == .openID(error))
    }

    @Test(arguments: [
        (AccountError.notSignedIn, ConnectFailure.sessionExpired), (.server(.sessionExpired), .sessionExpired),
        (.connectionNotFound, .serverNotSaved),
        (.keychain(KeychainError(status: errSecInteractionNotAllowed)), .keychainUnavailable),
        (.keychain(KeychainError(status: errSecDecode)), .unexpected),
    ])
    func mapsAccountErrors(error: AccountError, expected: ConnectFailure) {
        #expect(ConnectFailure(error) == expected)
    }

    @Test(arguments: [
        (KeychainError(status: errSecInteractionNotAllowed) as any Error, ConnectFailure.keychainUnavailable),
        (KeychainError(status: errSecNotAvailable), .keychainUnavailable),
        (KeychainError(status: errSecDecode), .unexpected),
        (CustomHeaderError.reserved(name: "Cookie"), .reservedHeader(name: "Cookie")),
        (URLError(.badURL), .unexpected), (APIError.notFound, .unexpected),
    ])
    func mapsOtherErrors(error: any Error, expected: ConnectFailure) {
        #expect(ConnectFailure(error) == expected)
    }

    @Test(arguments: [CancellationError() as any Error, OIDCLoginError.cancelled])
    func cancellationIsNotAFailure(error: any Error) {
        #expect(ConnectFailure(error) == nil)
    }
}
