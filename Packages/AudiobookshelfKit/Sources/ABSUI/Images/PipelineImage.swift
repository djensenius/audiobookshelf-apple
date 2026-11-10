import ABSCore
import SwiftUI

extension EnvironmentValues {
    /// The process-wide image pipeline that ``CoverView``, ``AuthorImageView`` and
    /// ``GroupCoverView`` load from. Without one they show their placeholders.
    @Entry public var imagePipeline: ImagePipeline? = nil
}

/// What a view asks the pipeline for at its rendered size: the width bucket is the smallest
/// one at least the rendered width × display scale (ADR 0005).
struct ImageLoadRequest: Hashable {
    var key: ImageKey
    var box: PixelBox

    init?(key: ImageKey?, size: CGSize, scale: Double) {
        guard let key, size.width > 0, size.height > 0, scale > 0 else { return nil }
        self.key = key.with(bucket: ImageWidthBucket(pixelWidth: size.width * scale))
        box = PixelBox(size: size, scale: scale)
    }
}

/// Loads `key` from the environment's pipeline at the rendered size and shows it, filling its
/// frame. Loading starts in `.task(id:)`, so it is cancelled when the view scrolls away.
///
/// When the image's aspect ratio differs from the frame's by more than 0.15, it is shown
/// aspect-fit over a blurred fill of itself, like the legacy covers.
struct PipelineImage<Placeholder: View, Failure: View>: View {
    let key: ImageKey?
    @ViewBuilder let placeholder: Placeholder
    @ViewBuilder let failure: Failure

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @State private var size = CGSize.zero
    @State private var image: CoverImage?
    /// The entity `image` shows; a different entity clears it rather than showing a stale cover.
    @State private var imageEntity: String?
    @State private var failed = false

    var body: some View {
        let request = ImageLoadRequest(key: key, size: size, scale: displayScale)
        Color.clear
            .overlay {
                if let image {
                    content(image)
                        .transition(.opacity)
                } else if failed || key == nil {
                    failure
                } else {
                    placeholder
                }
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                size = $0
            }
            .task(id: request) { await load(request) }
    }

    @ViewBuilder private func content(_ image: CoverImage) -> some View {
        let picture = Image(decorative: image.cgImage, scale: displayScale)
        let imageRatio = Double(image.pixelHeight) / Double(max(image.pixelWidth, 1))
        let frameRatio = size.width > 0 ? size.height / size.width : imageRatio
        if abs(imageRatio - frameRatio) > 0.15 {
            ZStack {
                picture.resizable().scaledToFill().blur(radius: 16, opaque: true)
                picture.resizable().scaledToFit()
            }
        } else {
            picture.resizable().scaledToFill()
        }
    }

    private func load(_ request: ImageLoadRequest?) async {
        guard let request else {
            image = nil
            return
        }
        guard let pipeline else { return }
        if imageEntity != request.key.entityID {
            image = nil
            failed = false
        }
        do {
            let loaded = try await pipeline.image(for: request.key, pixelBox: request.box)
            withAnimation(.easeIn(duration: 0.3)) {
                image = loaded
                imageEntity = request.key.entityID
                failed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            failed = true
        }
    }
}
