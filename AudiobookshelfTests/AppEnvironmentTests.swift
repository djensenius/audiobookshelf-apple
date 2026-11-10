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
            let environment = AppEnvironment(settings: settings, storeLocation: .inMemory)

            #expect(environment.settings === settings)
            #expect(environment.dataStack != nil)
            #expect(environment.lifecycle.gate == .launching)

            await environment.lifecycle.start()

            #expect(environment.lifecycle.gate == .connect)
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
            let environment = AppEnvironment(settings: settings, storeLocation: location)

            #expect(environment.dataStack == nil)

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

        // ADR 0004: the legacy scheme, once, and no second one.
        #expect(urlTypes.count == 1)
        let urlType = try #require(urlTypes.first)
        #expect(urlType["CFBundleURLName"] as? String == identifier)
        #expect(urlType["CFBundleTypeRole"] as? String == "Editor")
        let schemes = try #require(urlType["CFBundleURLSchemes"] as? [String])
        #expect(schemes == ["audiobookshelf"])

        // What the app registers is what `DeepLink` accepts.
        let url = try #require(URL(string: "\(schemes[0])://item/li_1"))
        #expect(DeepLink(url: url)?.target == .item(id: "li_1", episodeID: nil))
    }

    @Test(arguments: AppTab.allCases)
    func everyTabHasATitleAndASymbol(tab: AppTab) {
        #expect(L10n.string(tab.titleKey) != tab.titleKey, "\(tab) has no string for \(tab.titleKey)")
        #expect(symbolExists(tab.systemImage), "\(tab) has no SF Symbol named \(tab.systemImage)")
    }

    @Test(arguments: ["HeaderBrowse", "MessageStoreUnavailable", "MessageStoreUnavailableHelp"])
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
