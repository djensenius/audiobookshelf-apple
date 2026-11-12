import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct DownloadNetworkAccessTests {
    /// Settings and network access on one fresh store.
    private func make(
        policy: CellularPolicy, treatsExpensiveAsCellular: Bool
    ) throws -> (DownloadNetworkAccess, AppSettings, cleanUp: () -> Void) {
        let suiteName = "ABSAppModelTests.DownloadNetworkAccess.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.downloadUsingCellular = policy
        let access = DownloadNetworkAccess(defaults: defaults, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        return (access, settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func flagsFollowTheStoredPolicy() async throws {
        let (access, settings, cleanUp) = try make(policy: .ask, treatsExpensiveAsCellular: true)
        defer { cleanUp() }
        #expect(access.current() == NetworkAccess(policy: .ask, treatsExpensiveAsCellular: true))
        #expect(await access.provider() == NetworkAccess(policy: .ask, treatsExpensiveAsCellular: true))

        settings.downloadUsingCellular = .never

        let flags = access.current()
        #expect(!flags.allowsCellularAccess)
        #expect(!flags.allowsConstrainedNetworkAccess)
        #expect(!flags.allowsExpensiveNetworkAccess)
    }

    @Test func meteredAccessIsRecordedUntilTaken() throws {
        let (access, settings, cleanUp) = try make(policy: .never, treatsExpensiveAsCellular: false)
        defer { cleanUp() }
        // Unknown tasks from before it existed count as metered.
        #expect(access.takeHandedOutMetered())
        #expect(!access.takeHandedOutMetered())

        _ = access.current()
        #expect(!access.takeHandedOutMetered())

        for policy in [CellularPolicy.ask, .always] {
            settings.downloadUsingCellular = policy
            _ = access.current()
            // Copies share the record, as the engine's closure and the controller do.
            let copy = access
            #expect(copy.takeHandedOutMetered())
            #expect(!access.takeHandedOutMetered())
        }

        access.markHandedOutMetered()
        #expect(access.takeHandedOutMetered())
    }
}
