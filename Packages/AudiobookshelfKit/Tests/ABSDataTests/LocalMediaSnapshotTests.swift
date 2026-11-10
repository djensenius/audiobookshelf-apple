import Foundation
import Testing

@testable import ABSData

@Suite struct LocalMediaSnapshotTests {
    @Test func versionOneSnapshotDecodesWithoutCoverTime() throws {
        let json = """
            {"snapshotVersion": 1,
             "metadata": {"title": "The Book", "authors": [], "narrators": [], "series": [],
                          "explicit": false, "abridged": false},
             "chapters": [], "audioTracks": [], "episodes": []}
            """
        let snapshot = try JSONDecoder().decode(LocalMediaSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.snapshotVersion == 1)
        #expect(snapshot.metadata.title == "The Book")
        #expect(snapshot.coverUpdatedAt == nil)
    }

    @Test func versionTwoSnapshotRoundTripsCoverTime() throws {
        var snapshot = Fixtures.bookSnapshot
        snapshot.coverUpdatedAt = Fixtures.date
        let decoded = try JSONDecoder().decode(LocalMediaSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(snapshot.snapshotVersion == 2)
        #expect(decoded == snapshot)
        #expect(decoded.coverUpdatedAt == Fixtures.date)
    }
}
