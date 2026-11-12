import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor
@Suite struct AppEnvironmentTests {
    /// Settings in a throwaway defaults suite, so a test never touches the app's.
    private func withSettings(_ body: (AppSettings) async throws -> Void) async throws {
        let suiteName = "AppEnvironmentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppSettings(defaults: defaults))
    }

    @Test func buildsWithAnInMemoryStoreAndSettlesSignedOut() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain())

            #expect(environment.settings === settings)
            #expect(environment.dataStack != nil)
            #expect(environment.accounts != nil)
            // The library is the lifecycle's seeder, and stays cleared while signed out.
            #expect(environment.library != nil)
            #expect(environment.lifecycle.gate == .launching)

            await environment.lifecycle.start()

            #expect(environment.lifecycle.gate == .connect)
            #expect(environment.library?.store.connectionKey == nil)
        }
    }

    @Test func keepsTheDeviceIdentifierInTheInjectedKeychain() async throws {
        try await withSettings { settings in
            let keychain = ConnectTestKeychain()
            let environment = AppEnvironment(settings: settings, storeLocation: .inMemory, keychain: keychain)

            let identifier = await environment.deviceIdentifiers.deviceIdentifier()

            let stored = try #require(try keychain.data(for: DeviceIdentifierStore.item))
            #expect(String(decoding: stored, as: UTF8.self) == identifier)
            #expect(await environment.deviceIdentifiers.deviceIdentifier() == identifier)
        }
    }

    @Test func aStoreThatCantBeOpenedShowsStoreUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "AppEnvironmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the store's directory should be makes every load fail.
        let blocker = directory.appending(path: "Blocker")
        try Data().write(to: blocker)

        try await withSettings { settings in
            let location = DataStack.Location.url(blocker.appending(path: "Audiobookshelf.store"))
            let environment = AppEnvironment(
                settings: settings, storeLocation: location, keychain: ConnectTestKeychain())

            #expect(environment.dataStack == nil)
            #expect(environment.accounts == nil)

            await environment.lifecycle.start()

            guard case .storeUnavailable = environment.lifecycle.gate else {
                Issue.record("Expected the store-unavailable gate, got \(environment.lifecycle.gate)")
                return
            }
        }
    }

    @Test func declaresTheHandoffActivityType() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])

        #expect(types.contains(DeepLink.handoffActivityType))
    }

    @Test func registersTheLegacyURLScheme() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let urlTypes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])

        // ADR 0004: the legacy scheme, so links made for the old app open this one. It has to be
        // among the URL types, whatever else is registered.
        let urlType = try #require(
            urlTypes.first { ($0["CFBundleURLSchemes"] as? [String])?.contains("audiobookshelf") == true })
        #expect(urlType["CFBundleURLName"] as? String == identifier)
        #expect(urlType["CFBundleTypeRole"] as? String == "Editor")

        // What the app registers is what `DeepLink` accepts.
        let url = try #require(URL(string: "audiobookshelf://item/li_1"))
        #expect(DeepLink(url: url)?.target == .item(id: "li_1", episodeID: nil))
    }

    @Test func hostAppInfoPlistCarriesTheVersion() throws {
        // `PlaybackDeviceInfo` sends the host app's `CFBundleShortVersionString` to the server.
        let info = try #require(Bundle.main.infoDictionary)
        let marketing = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)

        let version = AppVersion()
        #expect(version.marketing == marketing)
        #expect(version.build == build)
        // Not AppVersion's fallback, so the host app's Info.plist was read.
        #expect(version != AppVersion(marketing: "0.0.0", build: "0"))
    }

    @Test(arguments: AppTab.allCases)
    func everyTabHasATitleAndASymbol(tab: AppTab) {
        #expect(L10n.string(tab.titleKey) != tab.titleKey, "\(tab) has no string for \(tab.titleKey)")
        #expect(symbolExists(tab.systemImage), "\(tab) has no SF Symbol named \(tab.systemImage)")
    }

    @Test(arguments: [
        "ButtonSwitchServer", "HeaderBrowse", "HeaderOpenLinkOnAnotherServer", "LabelMiniPlayerAccessibility",
        "LabelMiniPlayerHint", "MessageStoreUnavailable", "MessageStoreUnavailableHelp", "MessageSwitchServerForLink",
        "MessageSwitchServerSignedOut",
    ])
    func shellStringsResolve(key: String) {
        #expect(L10n.string(key) != key)
    }

    private func symbolExists(_ name: String) -> Bool {
        #if canImport(AppKit)
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
            UIImage(systemName: name) != nil
        #endif
    }
}
