import ABSCore
import Foundation

/// What the Account page (`pages/account.vue`) shows about the account beyond its saved
/// connection: the user's type, a warning for a server older than the app supports, and the
/// app's version. Pure functions, so the rules are testable without the view.
public enum AccountDetails {
    /// The localization key for a user type's label (Root, Admin, User or Guest): legacy's
    /// `LabelUser`, and `LabelAccountType…` keys named like the web client's for the others; `nil`
    /// for a type this client doesn't know, which the page shows as the server sent it.
    public static func userTypeKey(_ type: UserType) -> String? {
        switch type {
        case .root: "LabelAccountTypeRoot"
        case .admin: "LabelAccountTypeAdmin"
        case .user: "LabelUser"
        case .guest: "LabelAccountTypeGuest"
        case .unknown: nil
        }
    }

    /// Whether the saved server `version` is older than the app supports
    /// (``ServerFeatures/minimumSupported``, 2.26.0, the version below which legacy
    /// `ServerConnectForm.vue` warns with `isValidVersion`), so the page warns about it. An
    /// unparseable version is too old too, as the sign-in gate treats it; a missing one isn't,
    /// as legacy shows nothing without a saved version.
    public static func serverVersionWarning(_ version: String?) -> ServerVersionWarning? {
        guard let version else { return nil }
        guard let parsed = ServerVersion(version) else {
            return .unknownVersion(minimum: ServerFeatures.minimumSupported)
        }
        guard parsed < ServerFeatures.minimumSupported else { return nil }
        return .tooOld(version: version, minimum: ServerFeatures.minimumSupported)
    }

    /// The app's version and build from its bundle's `CFBundleShortVersionString` and
    /// `CFBundleVersion`, as "1.2.3 (45)", or either alone when the other is missing or the same.
    public static func appVersion(infoDictionary: [String: Any]?) -> String? {
        let version = nonEmpty(infoDictionary?["CFBundleShortVersionString"] as? String)
        let build = nonEmpty(infoDictionary?["CFBundleVersion"] as? String)
        switch (version, build) {
        case (let version?, let build?) where version != build: return "\(version) (\(build))"
        case (let version?, _): return version
        case (nil, let build?): return build
        case (nil, nil): return nil
        }
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Why the Account page warns about the server's version (``AccountDetails/serverVersionWarning(_:)``).
public enum ServerVersionWarning: Sendable, Hashable {
    /// The server runs `version`, older than `minimum`.
    case tooOld(version: String, minimum: ServerVersion)
    /// The saved version can't be read, so it can't be shown to be `minimum` or later.
    case unknownVersion(minimum: ServerVersion)
}
