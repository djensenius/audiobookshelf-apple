import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The year in review (legacy `components/stats/YearInReviewBanner.vue`): a year picker, a
/// switch between the user's and the server's year for admins, and the shareable card.
///
/// The card is shown as the image that is shared, rendered once its covers have loaded.
struct YearInReviewView: View {
    @Environment(\.statsService) private var service
    @State private var model: YearInReviewModel?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: L10n.string("HeaderYearInReview")))
            .task {
                guard let service else { return }
                let model = model ?? YearInReviewModel(service: service)
                self.model = model
                await model.loadIfNeeded()
            }
    }

    @ViewBuilder private var content: some View {
        if let model {
            YearInReviewContentView(model: model)
        } else if service == nil {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed"))
        } else {
            LoadingView()
        }
    }
}

private struct YearInReviewContentView: View {
    let model: YearInReviewModel

    @Environment(\.serverID) private var serverID
    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @State private var shareImage: YearInReviewShareImage?
    /// Whether the last render of the loaded stats produced no image.
    @State private var renderFailed = false

    /// What the rendered image depends on.
    private struct RenderKey: Equatable {
        var content: YearInReviewContent?
        var year: Int
        var variant: YearInReviewVariant
        var scale: Double
        var locale: Locale
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ABSSpacing.large) {
                controls
                if model.error != nil, model.content != nil, !model.isLoading {
                    RefreshFailedRow { Task { await model.load() } }
                }
                card
            }
            .padding(ABSSpacing.large)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let shareImage {
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview(
                            Text(verbatim: L10n.string("HeaderYearInReviewYear", String(model.year))),
                            image: Image(decorative: shareImage.cgImage, scale: renderScale))
                    ) {
                        Label {
                            Text(verbatim: L10n.string("ButtonShare"))
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            #if os(macOS)
                // No pull to refresh on macOS.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("ButtonRefresh"))
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isLoading)
                }
            #endif
        }
        .refreshable { await model.load() }
        .task(
            id: RenderKey(
                content: model.content, year: model.year, variant: model.variant, scale: renderScale, locale: locale)
        ) {
            await render()
        }
    }

    private var controls: some View {
        VStack(spacing: ABSSpacing.medium) {
            Picker(
                selection: Binding(get: { model.year }, set: { year in Task { await model.select(year: year) } })
            ) {
                ForEach(model.availableYears, id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            } label: {
                Text(verbatim: L10n.string("LabelYearInReviewYear"))
            }
            .pickerStyle(.menu)
            if model.availableVariants.count > 1 {
                Picker(
                    selection: Binding(
                        get: { model.variant }, set: { variant in Task { await model.select(variant: variant) } })
                ) {
                    ForEach(model.availableVariants) { variant in
                        Text(verbatim: L10n.string(Self.labelKey(variant))).tag(variant)
                    }
                } label: {
                    Text(verbatim: L10n.string("LabelYearInReviewVariant"))
                }
                .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder private var card: some View {
        if let shareImage, model.content != nil {
            Image(decorative: shareImage.cgImage, scale: renderScale)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: ABSRadius.large))
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text(verbatim: summary))
        } else if model.content == nil, model.error != nil, !model.isLoading {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed")) {
                Task { await model.load() }
            }
        } else if renderFailed, model.content != nil {
            ErrorStateView(title: L10n.string("MessageYearInReviewLoadFailed")) {
                Task { await render() }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    /// The display's scale, at least 2x, so the shared image is sharp on other screens too.
    private var renderScale: Double { max(displayScale, 2) }

    private var summary: String {
        guard let content = model.content else { return "" }
        return YearInReviewCard.summary(for: content, year: model.year, locale: locale)
    }

    static func labelKey(_ variant: YearInReviewVariant) -> String {
        switch variant {
        case .user: "LabelYearInReviewUser"
        case .server: "LabelYearInReviewServer"
        }
    }

    /// Loads the covers first, then renders the card: `ImageRenderer` doesn't wait for them.
    private func render() async {
        // Never show or share the previous year's or variant's image while this one renders.
        shareImage = nil
        renderFailed = false
        guard let content = model.content else { return }
        let year = model.year
        let variant = model.variant
        let covers = await YearInReviewCovers.load(ids: content.coverItemIDs, serverID: serverID, pipeline: pipeline)
        guard !Task.isCancelled else { return }
        let card = YearInReviewCard(content: content, year: year, covers: covers, locale: locale)
        shareImage = YearInReviewShareImage.render(card, variant: variant, scale: renderScale)
        renderFailed = shareImage == nil
    }
}
