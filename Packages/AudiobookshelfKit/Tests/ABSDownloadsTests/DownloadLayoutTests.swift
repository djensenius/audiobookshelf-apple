import Foundation
import Testing

@testable import ABSDownloads

@Suite struct DownloadLayoutTests {
    private let locations = DownloadLocations(root: URL(filePath: "/tmp/layout-unused", directoryHint: .isDirectory))
    private let connection = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func layout(_ itemID: String = "li_1", connection: UUID? = nil) throws -> DownloadLayout {
        try DownloadLayout(connectionID: connection ?? self.connection, libraryItemID: itemID, locations: locations)
    }

    @Test func buildsTheFolderLayout() throws {
        var layout = try layout()
        let folder = "00000000-0000-0000-0000-0000000000A1/li_1"
        #expect(layout.folder == folder)
        #expect(try layout.bookFilePath(filename: "Chapter 1.mp3") == "\(folder)/Chapter 1.mp3")
        #expect(try layout.coverPath() == "\(folder)/cover.jpg")
        #expect(
            try layout.episodeFilePath(episodeID: "ep_1", filename: "Show.mp3") == "\(folder)/episodes/ep_1/Show.mp3")
    }

    @Test func twoConnectionsWithTheSameItemIDGetDifferentFolders() throws {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        #expect(try layout("li_1").folder != layout("li_1", connection: other).folder)
    }

    /// Disc folders can repeat `01.mp3`; the legacy app overwrote the first.
    @Test func collidingNamesGetNumberedSuffixes() throws {
        var layout = try layout()
        let folder = layout.folder
        #expect(try layout.bookFilePath(filename: "01.mp3") == "\(folder)/01.mp3")
        #expect(try layout.bookFilePath(filename: "01.mp3") == "\(folder)/01 (2).mp3")
        #expect(try layout.bookFilePath(filename: "01.MP3") == "\(folder)/01 (3).MP3")
        #expect(try layout.bookFilePath(filename: "01 (2).mp3") == "\(folder)/01 (2) (2).mp3")
        // The cover and the episodes folder are taken already.
        #expect(try layout.bookFilePath(filename: "Cover.jpg") == "\(folder)/Cover (2).jpg")
        #expect(try layout.bookFilePath(filename: "episodes") == "\(folder)/episodes (2)")
        // Each episode folder has its own names.
        #expect(try layout.episodeFilePath(episodeID: "ep_1", filename: "a.mp3") == "\(folder)/episodes/ep_1/a.mp3")
        #expect(try layout.episodeFilePath(episodeID: "ep_2", filename: "a.mp3") == "\(folder)/episodes/ep_2/a.mp3")
        #expect(
            try layout.episodeFilePath(episodeID: "ep_1", filename: "a.mp3") == "\(folder)/episodes/ep_1/a (2).mp3")
    }

    /// The Mac's default volume folds case, so `Straße.mp3` and `STRASSE.mp3` are one file there.
    @Test func namesThatFoldToTheSameNameCollide() throws {
        var layout = try layout()
        let folder = layout.folder
        #expect(try layout.bookFilePath(filename: "Straße.mp3") == "\(folder)/Straße.mp3")
        #expect(try layout.bookFilePath(filename: "STRASSE.mp3") == "\(folder)/STRASSE (2).mp3")
        #expect(try layout.bookFilePath(filename: "οδος.mp3") == "\(folder)/οδος.mp3")
        #expect(try layout.bookFilePath(filename: "ΟΔΟΣ.mp3") == "\(folder)/ΟΔΟΣ (2).mp3")
        // NFD and NFC spellings are the same name.
        #expect(try layout.bookFilePath(filename: "Cafe\u{301}.mp3") == "\(folder)/Cafe\u{301}.mp3")
        #expect(try layout.bookFilePath(filename: "Caf\u{E9}.mp3") == "\(folder)/Caf\u{E9} (2).mp3")
    }

    /// A partly downloaded item's stored files keep their paths when more files are planned.
    @Test func reservedPathsAreNotReassigned() throws {
        var first = try layout()
        let stored = try first.bookFilePath(filename: "01.mp3")
        let episode = try first.episodeFilePath(episodeID: "ep_1", filename: "a.mp3")
        var later = try DownloadLayout(
            connectionID: connection, libraryItemID: "li_1", locations: locations,
            reserving: [stored, episode, try first.coverPath()])
        #expect(try later.bookFilePath(filename: "01.mp3") == "\(first.folder)/01 (2).mp3")
        #expect(
            try later.episodeFilePath(episodeID: "ep_1", filename: "A.MP3") == "\(first.folder)/episodes/ep_1/A (2).MP3"
        )
        #expect(
            try later.episodeFilePath(episodeID: "ep_2", filename: "a.mp3") == "\(first.folder)/episodes/ep_2/a.mp3")
    }

    @Test(arguments: [
        "00000000-0000-0000-0000-0000000000B2/li_1/01.mp3", "00000000-0000-0000-0000-0000000000A1/li_10/01.mp3",
        "00000000-0000-0000-0000-0000000000A1/li_1", "00000000-0000-0000-0000-0000000000A1/li_1/a/01.mp3",
        "00000000-0000-0000-0000-0000000000A1/li_1/episodes/ep_1/x/01.mp3",
    ])
    func refusesToReserveUnrelatedPaths(path: String) {
        #expect(throws: DownloadLayout.LayoutError.unrelatedPath(path)) {
            try DownloadLayout(
                connectionID: connection, libraryItemID: "li_1", locations: locations, reserving: [path])
        }
    }

    @Test func refusesToReserveTraversal() {
        let path = "00000000-0000-0000-0000-0000000000A1/li_1/../li_2/01.mp3"
        #expect(throws: DownloadLocations.PathError.invalidRelativePath(path)) {
            try DownloadLayout(
                connectionID: connection, libraryItemID: "li_1", locations: locations, reserving: [path])
        }
    }

    @Test(arguments: [
        ("../../etc/passwd", "_.._etc_passwd"),
        ("..", "file"),
        (".", "file"),
        ("", "file"),
        (".hidden.mp3", "hidden.mp3"),
        ("a/b\\c:d.mp3", "a_b_c_d.mp3"),
        ("bell\u{07}\u{0}\nname\u{7F}.mp3", "bell___name_.mp3"),
        ("Café.m4b", "Café.m4b"),
        ("👩\u{200D}👧 \u{0915}\u{094D}\u{200C}.mp3", "👩\u{200D}👧 \u{0915}\u{094D}\u{200C}.mp3"),
        ("evil\u{202E}3pm.exe\u{200B}\u{FEFF}\u{2028}\u{2029}.mp3", "evil_3pm.exe____.mp3"),
    ])
    func sanitisesFilenames(filename: String, expected: String) throws {
        #expect(DownloadLayout.sanitisedFilename(filename) == expected)
        var layout = try layout()
        let path = try layout.bookFilePath(filename: filename)
        #expect(path == "\(layout.folder)/\(expected)")
        #expect(try locations.fileURL(forRelativePath: path).path().hasPrefix(locations.downloadsRoot.path()))
    }

    @Test func escapesIdentifiersWithoutTraversalOrClashes() throws {
        #expect(try layout("..").folder.hasSuffix("/%2E."))
        #expect(try layout(".").folder.hasSuffix("/%2E"))
        #expect(try layout("a/b").folder.hasSuffix("/a%2Fb"))
        #expect(try layout("a/b").folder != layout("a_b").folder)
        #expect(try layout("a%2Fb").folder != layout("a/b").folder)
        // A case-insensitive volume would put these in one folder if case were kept.
        #expect(try layout("ABC").folder.hasSuffix("/%41%42%43"))
        #expect(try layout("ABC").folder.lowercased() != layout("abc").folder.lowercased())
        var layout = try layout()
        #expect(try layout.episodeFilePath(episodeID: "../x", filename: "a.mp3").hasSuffix("/episodes/%2E.%2Fx/a.mp3"))
        #expect(
            try layout.episodeFilePath(episodeID: "EP", filename: "a.mp3").lowercased()
                != layout.episodeFilePath(episodeID: "ep", filename: "a.mp3").lowercased())
        #expect(throws: DownloadLayout.LayoutError.invalidIdentifier("")) { try self.layout("") }
        #expect(throws: DownloadLayout.LayoutError.invalidIdentifier("")) {
            try layout.episodeFilePath(episodeID: "", filename: "a.mp3")
        }
        let long = String(repeating: "x", count: 256)
        #expect(throws: DownloadLayout.LayoutError.invalidIdentifier(long)) { try self.layout(long) }
    }

    @Test func limitsNamesTo255BytesWithoutSplittingCharacters() throws {
        // "é" is 2 bytes and "👩‍👩‍👧" is 18, so no cut lands on a character boundary by luck.
        for unit in ["é", "👩‍👩‍👧", "x"] {
            let name = String(repeating: unit, count: 300) + ".mp3"
            let cleaned = DownloadLayout.sanitisedFilename(name)
            #expect(cleaned.utf8.count <= 255)
            #expect(cleaned.utf8.count > 255 - unit.utf8.count - 4)
            #expect(cleaned.hasSuffix(".mp3"))
            #expect(cleaned.dropLast(4).allSatisfy { String($0) == unit })

            var layout = try layout()
            _ = try layout.bookFilePath(filename: name)
            let second = try layout.bookFilePath(filename: name)
            let component = String(second.split(separator: "/").last!)
            #expect(component.utf8.count <= 255)
            #expect(component.hasSuffix(" (2).mp3"))
            #expect(component.dropLast(8).allSatisfy { String($0) == unit })
        }
        // An over-long "extension" stays part of the shortened stem.
        let noExtension = "a." + String(repeating: "b", count: 300)
        #expect(DownloadLayout.sanitisedFilename(noExtension).utf8.count == 255)
    }
}
