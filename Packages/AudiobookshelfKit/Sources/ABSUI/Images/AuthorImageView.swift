import ABSCore
import SwiftUI

/// An author's photo loaded through the environment's ``ImagePipeline`` (port of legacy
/// `AuthorImage.vue`), or a person icon when the author has no image or it fails to load.
/// Size it with a frame; the photo fills it.
public struct AuthorImageView: View {
    private let key: ImageKey?
    private let name: String

    /// - Parameter key: The author image (kind ``ImageKind/authorImage``), or `nil` if the
    ///   author has no `imagePath`.
    public init(key: ImageKey?, name: String) {
        self.key = key
        self.name = name
    }

    public var body: some View {
        PipelineImage(key: key) {
            Rectangle().fill(ABSColor.surface)
        } failure: {
            ZStack {
                Rectangle().fill(ABSColor.surface)
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(ABSSpacing.large)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
        .clipShape(.rect(cornerRadius: ABSRadius.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isImage)
    }
}

#Preview("Author image") {
    HStack {
        AuthorImageView(key: nil, name: "Brandon Sanderson")
            .frame(width: 120, height: 150)
        AuthorImageView(
            key: ImageKey(serverID: UUID(), kind: .authorImage, entityID: "aut_1", updatedAt: 1),
            name: "Ursula K. Le Guin"
        )
        .frame(width: 120, height: 150)
    }
    .padding()
    .absBackground()
}
