import ABSCore
import SwiftUI

/// The shape of a library's covers: legacy `bookCoverAspectRatio` (height ÷ width).
public enum CoverShape: Sendable, Hashable {
    /// 1.6, for book libraries.
    case book
    /// 1.0, for podcast libraries (and square book covers settings).
    case square

    /// Height ÷ width.
    public var aspectRatio: CGFloat {
        switch self {
        case .book: 1.6
        case .square: 1
        }
    }
}

/// A library item cover loaded through the environment's ``ImagePipeline`` (port of legacy
/// `BookCover.vue`).
///
/// Shows the title and author on a placeholder when the item has no cover, a tinted icon if
/// loading fails, and fades the image in. Pass `progress` to show the listening progress bar.
public struct CoverView: View {
    private let key: ImageKey?
    private let title: String
    private let author: String?
    private let shape: CoverShape
    private let progress: Double?
    private let isFinished: Bool

    /// - Parameters:
    ///   - key: The cover, or `nil` if the item has none.
    ///   - progress: The listening progress `0...1`, or `nil` for no progress bar.
    public init(
        key: ImageKey?, title: String, author: String? = nil, shape: CoverShape = .book, progress: Double? = nil,
        isFinished: Bool = false
    ) {
        self.key = key
        self.title = title
        self.author = author
        self.shape = shape
        self.progress = progress
        self.isFinished = isFinished
    }

    public var body: some View {
        PipelineImage(key: key) {
            Rectangle().fill(ABSColor.secondarySurface)
        } failure: {
            CoverPlaceholder(title: title, author: author, showsIcon: key != nil)
        }
        .aspectRatio(1 / shape.aspectRatio, contentMode: .fit)
        .overlay {
            if progress != nil || isFinished {
                ProgressBarOverlay(progress: progress ?? 0, isFinished: isFinished)
            }
        }
        .clipShape(.rect(cornerRadius: ABSRadius.small))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [title, author].compactMap(\.self).joined(separator: ", ")))
        .accessibilityAddTraits(.isImage)
    }
}

/// The cover shown when an item has no cover image (its title and author) or when the image
/// fails to load (an icon on a tinted background).
public struct CoverPlaceholder: View {
    private let title: String
    private let author: String?
    private let showsIcon: Bool

    /// - Parameter showsIcon: Shows a book icon instead of the text, for a failed load.
    public init(title: String, author: String? = nil, showsIcon: Bool = false) {
        self.title = title
        self.author = author
        self.showsIcon = showsIcon
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(ABSColor.surface)
            if showsIcon {
                Image(systemName: "book.closed")
                    .font(.title)
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: ABSSpacing.xSmall) {
                    Text(verbatim: title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ABSColor.foreground)
                    if let author {
                        Text(verbatim: author)
                            .font(.caption2)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(ABSSpacing.small)
            }
        }
    }
}

#Preview("Covers") {
    HStack(alignment: .top, spacing: ABSSpacing.medium) {
        CoverView(key: nil, title: "Project Hail Mary", author: "Andy Weir", progress: 0.4)
        CoverView(
            key: ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_1", updatedAt: 1), title: "Dune",
            author: "Frank Herbert", isFinished: true)
        CoverView(key: nil, title: "The Daily", author: "The New York Times", shape: .square)
    }
    .frame(height: 200)
    .padding()
    .absBackground()
}
