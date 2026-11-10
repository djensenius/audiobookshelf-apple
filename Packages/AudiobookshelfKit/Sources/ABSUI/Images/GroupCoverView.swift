import ABSCore
import SwiftUI

/// The cover of a series, collection or playlist: up to four item covers fanned out across the
/// frame, the first on top (port of legacy `GroupCover.vue`). With no covers it shows the
/// group's name. Size it with a frame.
public struct GroupCoverView: View {
    private let name: String
    private let keys: [ImageKey]
    private let shape: CoverShape

    /// - Parameter keys: The covers of the group's first items; only the first four are shown.
    public init(name: String, keys: [ImageKey], shape: CoverShape = .book) {
        self.name = name
        self.keys = Array(keys.prefix(4))
        self.shape = shape
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = Self.layout(count: keys.count, size: proxy.size, aspectRatio: shape.aspectRatio)
            ZStack(alignment: .topLeading) {
                if keys.isEmpty {
                    CoverPlaceholder(title: name)
                } else {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        PipelineImage(key: key) {
                            Rectangle().fill(ABSColor.secondarySurface)
                        } failure: {
                            CoverPlaceholder(title: name, showsIcon: true)
                        }
                        .frame(width: layout.coverWidth, height: proxy.size.height)
                        .shadow(color: .black.opacity(0.4), radius: 2, x: 4)
                        .offset(x: layout.step * CGFloat(index))
                        .zIndex(Double(keys.count - index))
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: ABSRadius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isImage)
    }

    /// Legacy layout: one cover fills the frame; several are each a full-height cover, offset
    /// evenly so the last one ends at the right edge.
    nonisolated static func layout(count: Int, size: CGSize, aspectRatio: CGFloat) -> (
        coverWidth: CGFloat, step: CGFloat
    ) {
        guard count > 1 else { return (size.width, 0) }
        let coverWidth = min(size.width, size.height / aspectRatio)
        return (coverWidth, (size.width - coverWidth) / CGFloat(count - 1))
    }
}

#Preview("Group covers") {
    let serverID = UUID()
    let keys = (1...4).map { ImageKey(serverID: serverID, kind: .itemCover, entityID: "li_\($0)", updatedAt: 1) }
    VStack(spacing: ABSSpacing.medium) {
        GroupCoverView(name: "The Stormlight Archive", keys: keys)
            .frame(width: 240, height: 192)
        GroupCoverView(name: "Empty Collection", keys: [])
            .frame(width: 240, height: 192)
    }
    .padding()
    .absBackground()
}
