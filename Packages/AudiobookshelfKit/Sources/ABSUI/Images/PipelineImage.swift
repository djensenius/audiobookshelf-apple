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

/// Why a ``PipelineImage`` shows its fallback instead of an image.
enum ImageFallback: Hashable {
    /// There is nothing to load: no key, or no pipeline in the environment (as in previews).
    case noImage
    /// The load failed.
    case failed

    /// The fallback to show, or `nil` while loading or once loaded.
    static func resolve(hasKey: Bool, hasPipeline: Bool, failed: Bool) -> ImageFallback? {
        guard hasKey, hasPipeline else { return .noImage }
        return failed ? .failed : nil
    }
}

/// How a newly loaded image appears.
enum ImageReveal {
    /// The fade for an image that took `elapsed` to load: none when it arrived almost at once,
    /// as for a memory-cache hit when a cell scrolls back into view, so cached covers don't
    /// flash. The pipeline is an actor, so even a hit is asynchronous; the elapsed time tells
    /// them apart.
    static func animation(after elapsed: Duration) -> Animation? {
        elapsed < .milliseconds(50) ? nil : .easeIn(duration: 0.3)
    }
}

/// What a ``PipelineImage`` shows, and how each load step changes it. Generic over the image
/// so it can be tested without decoding.
struct ImageLoadState<Image> {
    private(set) var image: Image?
    /// The entity `image` shows; a different entity clears it rather than showing a stale cover.
    private(set) var entity: String?
    private(set) var failed = false

    /// Starts a load and returns whether to run it. With no request or no pipeline it clears
    /// everything, so the no-image fallback shows instead of an old bitmap.
    mutating func begin(_ request: ImageLoadRequest?, hasPipeline: Bool) -> Bool {
        guard let request, hasPipeline else {
            self = Self()
            return false
        }
        if entity != request.key.entityID {
            image = nil
            failed = false
        }
        return true
    }

    /// Publishes a load's result, unless its task was cancelled (the key changed or the view
    /// went away) in which case it is dropped, even if the load succeeded.
    mutating func finish(_ request: ImageLoadRequest, result: Result<Image, any Error>, isCancelled: Bool) {
        guard !isCancelled else { return }
        switch result {
        case .success(let loaded):
            image = loaded
            entity = request.key.entityID
            failed = false
        case .failure:
            image = nil
            failed = true
        }
    }

    /// Releases the image when the view goes off screen, so lazy cells don't hold bitmaps the
    /// pipeline counts against its memory cap. The entity is kept, so the reload when the view
    /// returns doesn't reset a failure, and its memory-cache hit appears without a fade.
    mutating func disappear() {
        image = nil
    }
}

/// Loads `key` from the environment's pipeline at the rendered size and shows it, filling its
/// frame. Loading starts in `.task(id:)`, so it is cancelled when the view scrolls away, and
/// the image is released then too.
///
/// When the image's aspect ratio differs from the frame's by more than 0.15, it is shown
/// aspect-fit over a blurred fill of itself, like the legacy covers.
struct PipelineImage<Placeholder: View, Failure: View>: View {
    let key: ImageKey?
    @ViewBuilder let placeholder: Placeholder
    @ViewBuilder let failure: (ImageFallback) -> Failure

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @State private var size = CGSize.zero
    @State private var state = ImageLoadState<CoverImage>()

    var body: some View {
        let request = ImageLoadRequest(key: key, size: size, scale: displayScale)
        Color.clear
            .overlay {
                if let image = state.image {
                    content(image)
                        .transition(.opacity)
                } else if let fallback = ImageFallback.resolve(
                    hasKey: key != nil, hasPipeline: pipeline != nil, failed: state.failed)
                {
                    failure(fallback)
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
            // Keyed on the pipeline's presence too, so one injected later starts the load.
            .task(id: pipeline == nil ? nil : request) { await load(request) }
            .onDisappear { state.disappear() }
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
        guard state.begin(request, hasPipeline: pipeline != nil), let request, let pipeline else { return }
        let start = ContinuousClock.now
        let result: Result<CoverImage, any Error>
        do {
            result = .success(try await pipeline.image(for: request.key, pixelBox: request.box))
        } catch {
            result = .failure(error)
        }
        // Checked after the await: a memory hit doesn't check cancellation, and the task can be
        // cancelled between a successful load and resuming here.
        let isCancelled = Task.isCancelled
        withAnimation(ImageReveal.animation(after: ContinuousClock.now - start)) {
            state.finish(request, result: result, isCancelled: isCancelled)
        }
    }
}
