import ABSCore
import Testing

@testable import ABSAppModel

@Suite struct AccountDetailsTests {
    @Test(arguments: [
        (UserType.root, "LabelAccountTypeRoot"), (.admin, "LabelAccountTypeAdmin"), (.user, "LabelUser"),
        (.guest, "LabelAccountTypeGuest"),
    ])
    func eachKnownUserTypeHasItsLabel(type: UserType, key: String) {
        #expect(AccountDetails.userTypeKey(type) == key)
    }

    /// A type the client doesn't know has no label; the page shows the server's value.
    @Test func anUnknownUserTypeHasNoLabel() {
        #expect(AccountDetails.userTypeKey(.unknown("superuser")) == nil)
    }

    /// Below 2.26.0, the minimum the app supports and legacy's `isValidVersion` threshold, warns.
    @Test(arguments: ["2.25.9", "2.3", "v1.9.0", "2.25.99-beta.1"])
    func aServerBelowTheMinimumIsTooOld(version: String) {
        #expect(
            AccountDetails.serverVersionWarning(version)
                == .tooOld(version: version, minimum: ServerFeatures.minimumSupported))
    }

    @Test(arguments: ["2.26.0", "2.26.3", "v2.30.1", "3.0", "2.26.0-beta.1"])
    func aSupportedServerHasNoWarning(version: String) {
        #expect(AccountDetails.serverVersionWarning(version) == nil)
    }

    /// No saved version shows nothing, as in legacy; one that can't be read warns as unknown.
    @Test func aMissingVersionHasNoWarningAndAnUnreadableOneIsUnknown() {
        #expect(AccountDetails.serverVersionWarning(nil) == nil)
        #expect(
            AccountDetails.serverVersionWarning("nightly")
                == .unknownVersion(minimum: ServerFeatures.minimumSupported))
    }

    @Test func appVersionShowsTheVersionAndBuild() {
        let info = ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "212"]
        #expect(AccountDetails.appVersion(infoDictionary: info) == "1.4.0 (212)")
    }

    /// Either part alone, once when they're the same, and nothing without either.
    @Test func appVersionFallsBackToWhatTheBundleHas() {
        #expect(AccountDetails.appVersion(infoDictionary: ["CFBundleShortVersionString": "1.4.0"]) == "1.4.0")
        #expect(
            AccountDetails.appVersion(infoDictionary: ["CFBundleVersion": "212", "CFBundleShortVersionString": " "])
                == "212")
        #expect(
            AccountDetails.appVersion(infoDictionary: [
                "CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "1.4.0",
            ])
                == "1.4.0")
        #expect(AccountDetails.appVersion(infoDictionary: [:]) == nil)
        #expect(AccountDetails.appVersion(infoDictionary: nil) == nil)
    }
}
