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

    @Test(arguments: [
        ("../../etc/passwd", "_.._etc_passwd"),
        ("..", "file"),
        (".", "file"),
        ("", "file"),
        (".hidden.mp3", "hidden.mp3"),
        ("a/b\\c:d.mp3", "a_b_c_d.mp3"),
        ("bell\u{07}\u{0}\nname\u{7F}.mp3", "bell___name_.mp3"),
        ("Café.m4b", "Café.m4b"),
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
        var layout = try layout()
        #expect(try layout.episodeFilePath(episodeID: "../x", filename: "a.mp3").hasSuffix("/episodes/%2E.%2Fx/a.mp3"))
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
