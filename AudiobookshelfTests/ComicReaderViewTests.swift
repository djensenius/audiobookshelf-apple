import ABSAppModel
import ABSUI
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

#if os(macOS)
    import AppKit
    import ImageIO
    import UniformTypeIdentifiers

    @MainActor
    @Suite struct ComicReaderViewTests {
        /// The comic's pages are one element for VoiceOver, labelled with the page number, whose
        /// named actions turn the pages in reading order and show the chrome (#675); with the chrome
        /// pinned, as while VoiceOver runs on iOS, there's no action to hide it.
        @Test(arguments: [false, true])
        func thePagesHaveActionsForThePagesAndTheChrome(pinned: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appending(path: "comic.cbz")
            let page = try Self.png()
            try TinyEPUB.zip((1...3).map { TinyEPUB.Entry(name: "\($0).png", body: page) }).write(to: file)
            let reported = Turns()
            try await AccessibilityTree.with {
                let hosting = NSHostingView(
                    rootView: ComicReaderView(
                        fileURL: file, showsControls: false, onTap: { reported.taps += 1 },
                        onPageChange: { location, _ in reported.locations.append(location) }
                    )
                    .environment(\.readerChromeIsPinned, pinned))
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.close() }
                @MainActor func pages(at number: Int) async throws -> NSObject? {
                    let label = L10n.string("LabelReaderPageNumber", number.formatted(), 3.formatted())
                    for _ in 0..<300 where AccessibilityTree.element(labelled: label, in: hosting) == nil {
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    return AccessibilityTree.element(labelled: label, in: hosting)
                }
                let previous = L10n.string("ButtonReaderPreviousPage")
                let next = L10n.string("ButtonReaderNextPage")
                let show = L10n.string("ButtonReaderShowControls")

                let first = try #require(try await pages(at: 1))
                #expect(
                    Set(AccessibilityTree.actionNames(of: first))
                        == (pinned ? [previous, next] : [previous, next, show]))
                #expect(AccessibilityTree.perform(next, on: first))
                let second = try #require(try await pages(at: 2))
                #expect(reported.locations == [.page(2)])
                #expect(AccessibilityTree.perform(previous, on: second))
                _ = try #require(try await pages(at: 1))
                #expect(reported.locations == [.page(2), .page(1)])
                if !pinned {
                    let shown = try #require(try await pages(at: 1))
                    #expect(AccessibilityTree.perform(show, on: shown))
                    #expect(reported.taps == 1)
                }
            }
        }

        /// A 4×6 white PNG, a comic page.
        private static func png() throws -> Data {
            let context = try #require(
                CGContext(
                    data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(
                CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }

    private final class Turns {
        var locations: [EbookLocation] = []
        var taps = 0
    }
#endif
