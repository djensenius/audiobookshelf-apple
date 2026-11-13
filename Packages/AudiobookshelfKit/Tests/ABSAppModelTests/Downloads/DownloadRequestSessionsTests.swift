import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct DownloadRequestSessionsTests {
    private let identity = SessionIdentity(connectionID: UUID(), userID: "user-1")

    private func context(sessionID: UInt64) -> SessionContext {
        SessionContext(identity: identity, client: nil, isOffline: false, sessionID: sessionID)
    }

    @Test func followsTheRunningSession() async {
        let sessions = DownloadRequestSessions { _ in true }
        #expect(sessions.session(for: identity.connectionID) == nil)

        await sessions.sessionDidStart(context(sessionID: 4))
        #expect(
            sessions.session(for: identity.connectionID)
                == DownloadRequestSession(connectionID: identity.connectionID, sessionID: 4, canDownload: true))
        #expect(sessions.session(for: UUID()) == nil)

        await sessions.sessionWillEnd(.signOut)
        #expect(sessions.session(for: identity.connectionID) == nil)

        await sessions.sessionDidStart(context(sessionID: 5))
        #expect(sessions.session(for: identity.connectionID)?.sessionID == 5)
    }

    @Test func readsThePermissionAtEachLookup() async {
        @MainActor final class Permission { var granted = false }
        let permission = Permission()
        let sessions = DownloadRequestSessions { _ in permission.granted }
        await sessions.sessionDidStart(context(sessionID: 1))

        #expect(sessions.session(for: identity.connectionID)?.canDownload == false)
        permission.granted = true
        #expect(sessions.session(for: identity.connectionID)?.canDownload == true)
    }
}
