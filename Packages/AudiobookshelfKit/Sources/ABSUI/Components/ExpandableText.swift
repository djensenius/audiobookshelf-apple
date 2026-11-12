import SwiftUI

/// Text limited to a few lines with a Read more / Read less toggle, shown only when the
/// text is actually truncated. Collapses again when the text changes.
///
/// ``init(html:collapsedLineLimit:)`` parses the HTML off the main actor once per distinct
/// `html` value and caches the result, so it is cheap to re-create from a parent's `body`.
/// Parsing is linear in the input; the text is empty until the first parse finishes.
public struct ExpandableText: View {
    private enum Source: Hashable {
        case attributed(AttributedString)
        case html(String)
    }

    private let source: Source
    private let collapsedLineLimit: Int
    @State private var parsedHTML: (html: String, text: AttributedString)?
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: AttributedString, collapsedLineLimit: Int = 4) {
        source = .attributed(text)
        self.collapsedLineLimit = collapsedLineLimit
    }

    public init(_ text: String, collapsedLineLimit: Int = 4) {
        self.init(AttributedString(text), collapsedLineLimit: collapsedLineLimit)
    }

    /// Renders the safe subset of `html` supported by ``HTMLText``.
    public init(html: String, collapsedLineLimit: Int = 4) {
        source = .html(html)
        self.collapsedLineLimit = collapsedLineLimit
    }

    private var text: AttributedString {
        switch source {
        case .attributed(let text): text
        case .html(let html): parsedHTML?.html == html ? parsedHTML?.text ?? AttributedString() : AttributedString()
        }
    }

    private var isTruncated: Bool { fullHeight > collapsedHeight + 1 }

    /// How Read more and Read less resize the text: animated, or at once with Reduce Motion.
    static func toggleAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .default
    }

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
                    // Clears any ancestor `.lineLimit`, which would cap the measured height.
                    Text(text)
                        .lineLimit(nil)
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
                    withAnimation(Self.toggleAnimation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
                } label: {
                    Text(verbatim: L10n.string(isExpanded ? "ButtonReadLess" : "ButtonReadMore"))
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: source) { isExpanded = false }
        .task(id: source) {
            guard case .html(let html) = source, parsedHTML?.html != html else { return }
            let parsed = await Task.detached(priority: .userInitiated) {
                HTMLText.attributedString(from: html)
            }
            .value
            guard !Task.isCancelled else { return }
            parsedHTML = (html, parsed)
        }
    }
}
