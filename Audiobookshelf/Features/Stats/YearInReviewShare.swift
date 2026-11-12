import ABSAppModel
import ABSUI
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The card rendered to a PNG for `ShareLink`.
struct YearInReviewShareImage: Transferable {
    let cgImage: CGImage
    let png: Data
    /// Like legacy's `audiobookshelf_my_<year>.png`; `server` for the server's year.
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName { $0.filename }
    }

    /// Renders `card` at `scale` pixels per point. `nil` when rendering or encoding fails.
    ///
    /// `ImageRenderer` draws a single frame and doesn't wait for anything asynchronous, so the
    /// card's covers must already be decoded (``YearInReviewCovers``).
    @MainActor
    static func render(_ card: YearInReviewCard, variant: YearInReviewVariant, scale: Double) -> Self? {
        let renderer = ImageRenderer(
            content:
                card
                .environment(\.locale, card.locale)
                .environment(\.dynamicTypeSize, .large))
        renderer.proposedSize = ProposedViewSize(YearInReviewCard.size)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage, let png = pngData(cgImage) else { return nil }
        let owner = variant == .server ? "server" : "my"
        return Self(cgImage: cgImage, png: png, filename: "audiobookshelf_\(owner)_\(card.year).png")
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
