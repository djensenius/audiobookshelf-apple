import Foundation
import Testing

@testable import ABSDownloads

@Suite struct DownloadLocationsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "locations-\(UUID().uuidString)")

    @Test func resolvesRelativePathsUnderDownloadsRoot() throws {
        let locations = DownloadLocations(root: root)
        let url = try locations.fileURL(forRelativePath: "li_1/Chapter 1.mp3")
        #expect(url == root.appending(path: "Downloads/li_1/Chapter 1.mp3"))
        #expect(locations.resumeDataRoot.path(percentEncoded: false).hasSuffix("/ResumeData/"))
    }

    @Test(arguments: [
        "", "/etc/passwd", "../outside.mp3", "li_1/../../outside.mp3", "./li_1/1.mp3", "li_1//1.mp3", "li_1/",
        // A combining mark after `/` joins it into one Character, but the `/` still separates.
        "../\u{0301}x", "li_1/../\u{0301}../x", "/\u{0301}etc/passwd", "./\u{0301}x", "li_1//\u{0301}x",
    ])
    func rejectsPathsThatCouldLeaveTheRoot(path: String) {
        #expect(throws: DownloadLocations.PathError.invalidRelativePath(path)) {
            try DownloadLocations(root: root).fileURL(forRelativePath: path)
        }
    }

    /// `..` followed by a combining mark is an ordinary name, not the parent directory.
    @Test(arguments: ["li_1/..\u{0301}/1.mp3", "li_1/\u{0301}x/1.mp3", "\u{0301}../1.mp3", ".\u{0301}/1.mp3"])
    func acceptsCombiningMarkNamesInsideTheRoot(path: String) throws {
        let locations = DownloadLocations(root: root)
        let url = try locations.fileURL(forRelativePath: path)
        // Compare scalars: a combining mark would merge with the root's trailing `/` as Characters.
        let resolved = url.standardizedFileURL.path(percentEncoded: false).unicodeScalars
        #expect(
            resolved.starts(
                with: locations.downloadsRoot.standardizedFileURL.path(percentEncoded: false).unicodeScalars))
        let depth = path.unicodeScalars.split(separator: "/").count
        #expect(url.standardizedFileURL.pathComponents.count == locations.downloadsRoot.pathComponents.count + depth)
    }

    @Test func prepareCreatesDirectoriesExcludedFromBackup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DownloadLocations(root: root)

        try locations.prepare()
        let file = try locations.fileURL(forRelativePath: "li_1/1.mp3")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: file)
        // Running it again changes nothing.
        try locations.prepare()

        for directory in [locations.downloadsRoot, locations.resumeDataRoot] {
            // A fresh URL, so no cached values are read.
            let values = try URL(filePath: directory.path(percentEncoded: false))
                .resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
            #expect(values.isDirectory == true)
            #expect(values.isExcludedFromBackup == true)
            #if os(iOS)
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
                #expect(
                    attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
            #endif
        }
        #expect(try Data(contentsOf: file) == Data("kept".utf8))
    }

    @Test func moveReplacesExistingFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try DownloadLocations(root: root).fileURL(forRelativePath: "li_1/1.mp3")
        let first = root.appending(path: "first.tmp")
        let second = root.appending(path: "second.tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: first)
        try Data("newer".utf8).write(to: second)

        try DownloadLocations.moveFile(at: first, to: destination)
        try DownloadLocations.moveFile(at: second, to: destination)

        #expect(try Data(contentsOf: destination) == Data("newer".utf8))
        #expect(DownloadLocations.fileSize(at: destination) == 5)
        #expect(!FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
        #expect(DownloadLocations.fileSize(at: root.appending(path: "missing")) == nil)
    }

    @Test func recognisesOutOfSpaceErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(DownloadLocations.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(DownloadLocations.isOutOfSpace(wrapped))
        #expect(!DownloadLocations.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
        #expect(!DownloadLocations.isOutOfSpace(URLError(.networkConnectionLost)))
    }
}
