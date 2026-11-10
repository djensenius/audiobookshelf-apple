import SwiftUI

/// Text limited to a few lines with a Read more / Read less toggle, shown only when the
/// text is actually truncated. Use ``init(html:collapsedLineLimit:)`` for server
/// descriptions.
public struct ExpandableText: View {
    private let text: AttributedString
    private let collapsedLineLimit: Int
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    public init(_ text: AttributedString, collapsedLineLimit: Int = 4) {
        self.text = text
        self.collapsedLineLimit = collapsedLineLimit
    }

    public init(_ text: String, collapsedLineLimit: Int = 4) {
        self.init(AttributedString(text), collapsedLineLimit: collapsedLineLimit)
    }

    /// Renders the safe subset of `html` supported by ``HTMLText``.
    public init(html: String, collapsedLineLimit: Int = 4) {
        self.init(HTMLText.attributedString(from: html), collapsedLineLimit: collapsedLineLimit)
    }

    private var isTruncated: Bool { fullHeight > collapsedHeight + 1 }

    public var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            Text(text)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    if !isExpanded { collapsedHeight = height }
                }
                .background(alignment: .topLeading) {
                    // Measures the untruncated height at the same width.
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fullHeight = $0
                        }
                        .accessibilityHidden(true)
                }
            if isTruncated || isExpanded {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Text(verbatim: L10n.string(isExpanded ? "ButtonReadLess" : "ButtonReadMore"))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
