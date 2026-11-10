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

/// How a newly shown image appears.
enum ImageReveal: Hashable {
    /// A memory-cache hit, read synchronously before the frame renders: at full opacity with no
    /// transition, so cached covers don't flash when a cell scrolls back into view.
    case immediate
    /// An image the pipeline loaded from disk or the network: a 0.3 s fade, like the legacy
    /// covers.
    case fade

    var animation: Animation? {
        switch self {
        case .immediate: nil
        case .fade: .easeIn(duration: 0.3)
        }
    }

    var transition: AnyTransition {
        switch self {
        case .immediate: .identity
        case .fade: .opacity
        }
    }
}

/// The cover a ``PipelineImage`` shows, whatever its size, bucket or version: the same entity
/// ID on another server (such as a cloned library) is a different cover.
struct CoverIdentity: Hashable {
    var serverID: UUID
    var kind: ImageKind
    var entityID: String

    init(_ key: ImageKey) {
        serverID = key.serverID
        kind = key.kind
        entityID = key.entityID
    }
}

/// What a ``PipelineImage`` shows, and how each load step changes it. Generic over the image
/// so it can be tested without decoding.
struct ImageLoadState<Image> {
    private(set) var image: Image?
    /// How `image` appeared, which picks its transition.
    private(set) var reveal = ImageReveal.fade
    /// The cover `image` shows; a different one clears it rather than showing a stale cover,
    /// while a new size or version of the same one keeps it until the new image arrives.
    private(set) var entity: CoverIdentity?
    /// The request `image` is exactly for: its size, bucket and version.
    private(set) var shown: ImageLoadRequest?
    private(set) var failed = false

    /// Starts showing `request` and returns whether it still has to be loaded. An image already
    /// shown for it needs no load; otherwise `memoryHit` (the pipeline's synchronous lookup) is
    /// asked, and a hit is shown at once with ``ImageReveal/immediate``. With no request or no
    /// pipeline it clears everything, so the no-image fallback shows instead of an old bitmap.
    mutating func begin(
        _ request: ImageLoadRequest?, hasPipeline: Bool, memoryHit: (ImageLoadRequest) -> Image? = { _ in nil }
    ) -> Bool {
        guard let request, hasPipeline else {
            self = Self()
            return false
        }
        if image != nil, shown == request { return false }
        if let hit = memoryHit(request) {
            show(hit, for: request, reveal: .immediate)
            return false
        }
        if entity != CoverIdentity(request.key) {
            image = nil
            failed = false
        }
        return true
    }

    /// Publishes a load's result, which fades in, unless its task was cancelled (the key changed
    /// or the view went away) in which case it is dropped, even if the load succeeded.
    mutating func finish(_ request: ImageLoadRequest, result: Result<Image, any Error>, isCancelled: Bool) {
        guard !isCancelled else { return }
        switch result {
        case .success(let loaded):
            show(loaded, for: request, reveal: .fade)
        case .failure:
            image = nil
            shown = nil
            failed = true
        }
    }

    /// Releases the image when the view goes off screen, so lazy cells don't hold bitmaps the
    /// pipeline counts against its memory cap. The entity is kept, so the reload when the view
    /// returns doesn't reset a failure.
    mutating func disappear() {
        image = nil
        shown = nil
    }

    private mutating func show(_ loaded: Image, for request: ImageLoadRequest, reveal: ImageReveal) {
        image = loaded
        self.reveal = reveal
        entity = CoverIdentity(request.key)
        shown = request
        failed = false
    }
}

/// Loads `key` from the environment's pipeline at the rendered size and shows it, filling its
/// frame. A memory-cache hit shows on the first frame with no transition; an image loaded from
/// disk or the network fades in. Loading runs in `.task(id:)`, so it is cancelled when the view
/// scrolls away, and the image is released then too.
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
        // `nil` without a pipeline too, so one injected later starts the load.
        let request = pipeline == nil ? nil : ImageLoadRequest(key: key, size: size, scale: displayScale)
        Color.clear
            .overlay {
                if let image = state.image {
                    content(image)
                        .transition(state.reveal.transition)
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
            // SwiftUI runs these in the update, before the frame renders, so a memory hit read
            // in them shows on that frame: when the view (re)appears, and when its size or key
            // changes. `.task` starts after the frame and loads only what missed.
            .onAppear { begin(request) }
            .onChange(of: request) { _, newRequest in begin(newRequest) }
            .task(id: request) { await load(request) }
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

    /// Starts showing `request`, at once if the pipeline's memory cache has it, and returns
    /// whether it still has to be loaded.
    @discardableResult private func begin(_ request: ImageLoadRequest?) -> Bool {
        let pipeline = pipeline
        return withAnimation(ImageReveal.immediate.animation) {
            state.begin(request, hasPipeline: pipeline != nil) {
                pipeline?.cachedImage(for: $0.key, pixelBox: $0.box)
            }
        }
    }

    private func load(_ request: ImageLoadRequest?) async {
        guard begin(request), let request, let pipeline else { return }
        let result: Result<CoverImage, any Error>
        do {
            result = .success(try await pipeline.image(for: request.key, pixelBox: request.box))
        } catch {
            result = .failure(error)
        }
        // Checked after the await: a memory hit doesn't check cancellation, and the task can be
        // cancelled between a successful load and resuming here.
        let isCancelled = Task.isCancelled
        withAnimation(ImageReveal.fade.animation) {
            state.finish(request, result: result, isCancelled: isCancelled)
        }
    }
}
